#!/bin/bash
set -x

# ==============================================================================
# 1. 환경 변수 로드
# ==============================================================================
source /home/ec2-user/.deploy_env

echo "================================================="
echo "▶ 배포된 애플리케이션 및 인프라 리소스 초기화 시작"
echo "================================================="

# ==============================================================================
# 2. 외부 노출 리소스 (LoadBalancer) 우선 삭제
# ==============================================================================
echo ">> [1/6] Deleting ArgoCD and Monitoring Stacks..."
# ArgoCD 삭제
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --ignore-not-found

# Helm Release 삭제 (모니터링 및 비용 관리 툴)
helm uninstall monitoring-stack -n monitoring --ignore-not-found
helm uninstall kube-ops-view -n monitoring --ignore-not-found
helm uninstall kubecost -n kubecost --ignore-not-found

# AWS 상에서 LoadBalancer 리소스가 반납될 수 있도록 대기
echo "Waiting for AWS LoadBalancers to be destroyed (60s)..."
sleep 60

# ==============================================================================
# 3. 오토스케일링 자원 삭제 (Karpenter)
# ==============================================================================
echo ">> [2/6] Deleting Karpenter NodePool and EC2NodeClass..."
kubectl delete nodepool default --ignore-not-found
kubectl delete ec2nodeclass default --ignore-not-found

# ==============================================================================
# 4. 핵심 컨트롤러 및 메트릭 서버 삭제
# ==============================================================================
echo ">> [3/6] Uninstalling Core Controllers (ALB & Karpenter)..."
helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found
helm uninstall karpenter -n karpenter --ignore-not-found

echo ">> [4/6] Deleting Metrics Server..."
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --ignore-not-found

# ==============================================================================
# 5. IAM Service Account (IRSA) 권한 회수
# ==============================================================================
echo ">> [5/6] Deleting IAM Service Accounts (IRSA)..."
eksctl delete iamserviceaccount --cluster $C --region $R --name aws-load-balancer-controller --namespace kube-system --wait || true
eksctl delete iamserviceaccount --cluster $C --region $R --name karpenter --namespace karpenter --wait || true

# ==============================================================================
# 6. 네임스페이스 및 클러스터 설정 원복
# ==============================================================================
echo ">> [6/6] Deleting Namespaces and Reverting CNI settings..."
for ns in dev stg prod monitoring kubecost argocd karpenter; do 
  kubectl delete namespace $ns --ignore-not-found
done

# VPC CNI Prefix Delegation 환경변수 제거 (원복)
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION- WARM_PREFIX_TARGET-

set +x
echo "================================================="
echo "🎉 모든 애플리케이션 초기화(Clean-up)가 완료되었습니다."
echo "================================================="