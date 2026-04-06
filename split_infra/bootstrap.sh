#!/bin/bash
set -ex

# ==============================================================================
# 1. 환경 변수 로드 및 로그 디렉토리 준비
# ==============================================================================
source /home/ec2-user/.deploy_env
LOG_DIR="/home/ec2-user/bootstrap_logs"
mkdir -p $LOG_DIR

set +x 
echo "================================================="
echo "▶ 병렬 배포 스크립트 시작 (로그 저장소: $LOG_DIR)"
echo "================================================="
set -x

# ==============================================================================
# 2. 클러스터 공통 설정 (빠른 작업, Foreground 실행)
# ==============================================================================
# 2-1) VPC CNI Prefix Delegation 설정
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1
# 2-2) OIDC 공급자 연동
eksctl utils associate-iam-oidc-provider --cluster $C --region $R --approve

# 2-3) 네임스페이스 생성
for ns in dev stg prod monitoring kubecost argocd; do 
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - 
done

# 2-4) EBS CSI 컨트롤러 권한 부여 및 재시작 대기
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster $C \
  --region $R \
  --attach-policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
  --approve \
  --role-name "${SERVICE_NAME}-ebs-csi-role" \
  --override-existing-serviceaccounts

# 새로운 권한을 물고 파드가 다시 뜰 수 있도록 재시작
kubectl rollout restart deployment ebs-csi-controller -n kube-system

# [안정화 코드] 컨트롤러가 정상적으로 뜰 때까지 스크립트 진행을 멈추고 대기 (최대 2분)
kubectl wait --for=condition=available deployment/ebs-csi-controller -n kube-system --timeout=120s

# 2-5) [신규 추가] 기본 StorageClass를 최신 고성능 gp3로 설정
echo ">> Configuring Default StorageClass (gp3)..."
kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF

# ==============================================================================
# 3. [백그라운드] Karpenter 스택 설치
# ==============================================================================
(
  set -ex
  eksctl create iamserviceaccount --cluster $C --region $R --name karpenter --namespace karpenter \
    --role-name "${SERVICE_NAME}-karpenter-controller-role" \
    --attach-policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" --approve --override-existing-serviceaccounts

  E=$(aws eks describe-cluster --name $C --query 'cluster.endpoint' --output text)
  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.2.0 -n karpenter \
    --set serviceAccount.create=false,serviceAccount.name=karpenter,settings.clusterName=$C,settings.clusterEndpoint=$E --wait

  cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: {name: default}
spec:
  template:
    spec:
      nodeClassRef: {group: karpenter.k8s.aws, kind: EC2NodeClass, name: default}
      requirements:
        - {key: "karpenter.sh/capacity-type", operator: In, values: ["spot"]}
        - {key: "kubernetes.io/arch", operator: In, values: ["amd64"]}
        - {key: "node.kubernetes.io/instance-type", operator: In, values: ["${APP_NODE_INSTANCE_TYPE}"]}
  limits: {cpu: 100}
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata: {name: default}
spec:
  amiSelectorTerms: [{alias: al2023@latest}]
  role: "${EKS_NODE_ROLE}"
  subnetSelectorTerms: [{tags: {"karpenter.sh/discovery": "$C"}}]
  securityGroupSelectorTerms: [{tags: {"karpenter.sh/discovery": "$C"}}]
EOF
) > $LOG_DIR/1_karpenter.log 2>&1 &
PID_KARPENTER=$!

# ==============================================================================
# 4. [백그라운드] AWS Load Balancer Controller 설치
# ==============================================================================
(
  set -ex
  eksctl create iamserviceaccount --cluster $C --region $R --namespace kube-system \
    --name aws-load-balancer-controller --role-name "${SERVICE_NAME}-alb-controller-role" \
    --attach-policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" --approve --override-existing-serviceaccounts

  helm repo add eks https://aws.github.io/eks-charts && helm repo update
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
    --set clusterName=$C,serviceAccount.create=false,serviceAccount.name=aws-load-balancer-controller,vpcId=${MAIN_VPC},region=$R --wait
) > $LOG_DIR/2_alb_controller.log 2>&1 &
PID_ALB=$!

# ==============================================================================
# 5. [백그라운드] Monitoring & Metrics Stack 설치
# ==============================================================================
(
  set -ex
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm upgrade --install monitoring-stack prometheus-community/kube-prometheus-stack -n monitoring \
    --set grafana.adminPassword='admin' \
    --set grafana.service.type=LoadBalancer \
    --set "grafana.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type=external" \
    --set "grafana.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type=ip" \
    --set "grafana.service.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme=internet-facing" \
    --wait

  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  
  helm repo add christianhuth https://charts.christianhuth.de
  helm upgrade --install kube-ops-view christianhuth/kube-ops-view -n monitoring \
    --set rbac.create=true,service.type=LoadBalancer --wait
) > $LOG_DIR/3_monitoring.log 2>&1 &
PID_MONITOR=$!

# ==============================================================================
# 6. [백그라운드] Kubecost 설치 (최대 타임아웃 요구)
# ==============================================================================
(
  set -ex
  helm repo add kubecost https://kubecost.github.io/cost-analyzer/ && helm repo update
  helm upgrade --install kubecost kubecost/cost-analyzer -n kubecost \
    --version 2.8.4 \
    --set kubecostProductConfigs.clusterName=$C \
    --set service.type=LoadBalancer \
    --timeout 10m \
    --wait
) > $LOG_DIR/4_kubecost.log 2>&1 &
PID_KUBECOST=$!

# ==============================================================================
# 7. [백그라운드] ArgoCD 설치
# ==============================================================================
(
  set -ex
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
  kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

  H=$(python3 -c "import crypt; print(crypt.crypt('admin123', crypt.mksalt(crypt.METHOD_BLOWFISH)))")
  kubectl patch secret argocd-secret -n argocd -p "{\"stringData\": {\"admin.password\": \"$H\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
  kubectl -n argocd delete secret argocd-initial-admin-secret || true
  kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
) > $LOG_DIR/5_argocd.log 2>&1 &
PID_ARGOCD=$!

# ==============================================================================
# 8. 동기화 대기 및 실시간 대시보드 출력
# ==============================================================================
set +x

# 작업 이름과 PID 배열 매핑
NAMES=("Karpenter 설치" "ALB Controller 설치" "Monitoring 스택 설치" "Kubecost 설치" "ArgoCD 설치")
PIDS=($PID_KARPENTER $PID_ALB $PID_MONITOR $PID_KUBECOST $PID_ARGOCD)
STATUS=("진행 중 ⏳" "진행 중 ⏳" "진행 중 ⏳" "진행 중 ⏳" "진행 중 ⏳")
DONE=(0 0 0 0 0)

# 터미널 커서 숨기기 (화면 깜빡임 방지용)
tput civis || true 

while true; do
  clear # 화면 갱신
  echo "================================================="
  echo "⏳ EKS 인프라 병렬 배포 실시간 현황"
  echo "전체 로그 확인: tail -f $LOG_DIR/*.log"
  echo "================================================="
  
  ALL_DONE=1
  for i in "${!PIDS[@]}"; do
    if [ ${DONE[$i]} -eq 0 ]; then
      # 프로세스가 실행 중인지 확인
      if ! kill -0 ${PIDS[$i]} 2>/dev/null; then
        # 프로세스 종료됨 -> 종료 상태 코드 수집
        wait ${PIDS[$i]}
        if [ $? -eq 0 ]; then
          STATUS[$i]="완료 ✅"
        else
          STATUS[$i]="실패 ❌ (로그 확인 필요)"
        fi
        DONE[$i]=1
      else
        # 하나라도 돌고 있으면 ALL_DONE은 0
        ALL_DONE=0
      fi
    fi
    # 포맷팅하여 상태 출력
    printf "%-30s : %s\n" "${NAMES[$i]}" "${STATUS[$i]}"
  done
  
  echo "================================================="
  
  # 모두 완료되었으면 루프 탈출
  if [ $ALL_DONE -eq 1 ]; then
    break
  fi
  
  # 2초마다 갱신
  sleep 2
done

# 터미널 커서 원상 복구
tput cnorm || true 

echo "🎉 모든 애플리케이션 배포 프로세스가 종료되었습니다."
echo "================================================="