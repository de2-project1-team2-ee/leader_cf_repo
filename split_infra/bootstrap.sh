#!/bin/bash
set -ex

# ==============================================================================
# 1. 환경 변수 자동 로드 (CFN UserData가 생성한 파일 사용)
# ==============================================================================
source /home/ec2-user/.deploy_env

# 출력을 깔끔하게 보기 위해 잠시 실행 명령어 표기(set -x)를 끕니다.
set +x 
echo "================================================="
echo "▶ 로드된 배포 환경 변수 전체 목록 (In-Memory 검증)"
echo "================================================="
echo "- SERVICE_NAME           : $SERVICE_NAME"
echo "- REGION (R)             : $R"
echo "- CLUSTER_NAME (C)       : $C"
echo "- APP_NODE_INSTANCE_TYPE : $APP_NODE_INSTANCE_TYPE"
echo "- EKS_NODE_ROLE          : $EKS_NODE_ROLE"
echo "- MAIN_VPC               : $MAIN_VPC"
echo "- APP_ENVIRONMENT        : $APP_ENVIRONMENT"
echo "================================================="
set -x # 다시 명령어 표기 모드를 켭니다.

# ==============================================================================
# 2. 클러스터 기본 설정 (OIDC & 네임스페이스)
# ==============================================================================
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true WARM_PREFIX_TARGET=1

eksctl utils associate-iam-oidc-provider --cluster $C --region $R --approve

for ns in dev stg prod monitoring; do 
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - 
done

# ==============================================================================
# 3. Karpenter 설치
# ==============================================================================
eksctl create iamserviceaccount --cluster $C --region $R --name karpenter --namespace karpenter \
  --role-name "${SERVICE_NAME}-karpenter-controller-role" \
  --attach-policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" --approve --override-existing-serviceaccounts

E=$(aws eks describe-cluster --name $C --query 'cluster.endpoint' --output text)
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.2.0 -n karpenter \
  --set serviceAccount.create=false,serviceAccount.name=karpenter,settings.clusterName=$C,settings.clusterEndpoint=$E --wait

# Karpenter NodePool 및 EC2NodeClass 적용
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

# ==============================================================================
# 4. AWS Load Balancer Controller 설치
# ==============================================================================
eksctl create iamserviceaccount --cluster $C --region $R --namespace kube-system \
  --name aws-load-balancer-controller --role-name "${SERVICE_NAME}-alb-controller-role" \
  --attach-policy-arn "arn:aws:iam::aws:policy/AdministratorAccess" --approve --override-existing-serviceaccounts

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=$C,serviceAccount.create=false,serviceAccount.name=aws-load-balancer-controller,vpcId=${MAIN_VPC},region=$R --wait

# ==============================================================================
# 5. Monitoring Stack (Prometheus, Kubecost, Kube-ops-view, Metrics Server)
# ==============================================================================
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring-stack prometheus-community/kube-prometheus-stack -n monitoring \
  --set grafana.adminPassword='admin',grafana.service.type=LoadBalancer --wait

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl create namespace ${APP_ENVIRONMENT} --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kubecost --dry-run=client -o yaml | kubectl apply -f -

helm repo add kubecost https://kubecost.github.io/cost-analyzer/ && helm repo update
helm upgrade --install kubecost kubecost/cost-analyzer -n kubecost \
  --set kubecostProductConfigs.clusterName=$C,service.type=LoadBalancer --wait

helm repo add christianhuth https://charts.christianhuth.de
helm upgrade --install kube-ops-view christianhuth/kube-ops-view -n monitoring \
  --set rbac.create=true,service.type=LoadBalancer --wait

# ==============================================================================
# 6. ArgoCD 설치 및 설정
# ==============================================================================
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

H=$(python3 -c "import crypt; print(crypt.crypt('admin123', crypt.mksalt(crypt.METHOD_BLOWFISH)))")
kubectl patch secret argocd-secret -n argocd -p "{\"stringData\": {\"admin.password\": \"$H\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"
kubectl -n argocd delete secret argocd-initial-admin-secret || true
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

echo "================================================="
echo "모든 애플리케이션 설치가 완료되었습니다."
echo "================================================="