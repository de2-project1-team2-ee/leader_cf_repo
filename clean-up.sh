#!/bin/bash
# ==============================================================================
# EKS Cluster Clean-up Script (v0.5.1 - 비동기 삭제 대기 로직 추가)
# ==============================================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}===========================================================${NC}"
echo -e "🧹 EKS 내부 리소스 자동 정리를 시작합니다..."
echo -e "${GREEN}===========================================================${NC}"

CLUSTER_NAME=$(aws eks list-clusters --query "clusters[0]" --output text)
if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "None" ]]; then
    echo -e "${RED}❌ EKS 클러스터를 찾을 수 없습니다.${NC}"
    exit 1
fi
SERVICE_NAME=${CLUSTER_NAME%-cluster}
REGION=$(aws configure get region)

echo -e "✅ 타겟 ServiceName: ${GREEN}$SERVICE_NAME${NC}"
echo -e "✅ 타겟 클러스터: ${GREEN}$CLUSTER_NAME${NC}"

# 1. Karpenter 리소스 삭제
echo -e "\n[Step 1] Karpenter NodePool 및 EC2 반납 유도..."
kubectl delete nodepool default --timeout=60s 2>/dev/null || true
kubectl delete ec2nodeclass default --timeout=60s 2>/dev/null || true

# 2. 로드밸런서(Ingress/SVC) 삭제 트리거
echo -e "\n[Step 2] 외부 LoadBalancer 리소스(CLB/ALB) 3종 삭제 트리거..."
kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || true
kubectl delete svc argocd-server -n argocd --timeout=60s 2>/dev/null || true
kubectl delete svc monitoring-stack-grafana -n monitoring --timeout=60s 2>/dev/null || true

# 3. [핵심] AWS 비동기 삭제 완벽 대기 로직
echo -e "\n${YELLOW}[Step 3] AWS 상에서 로드밸런서가 완전히 파괴될 때까지 대기합니다. (최대 5분 소요될 수 있음)${NC}"
echo "이 단계를 기다리지 않으면 IAM 권한이 먼저 삭제되어 CFN VPC 삭제가 실패합니다."

for i in {1..30}; do
    # ALB와 CLB를 생성하는 쿠버네티스 리소스가 남아있는지 확인
    LB_COUNT=$(kubectl get svc,ingress --all-namespaces 2>/dev/null | grep -c "LoadBalancer\|alb" || echo 0)

    if [ "$LB_COUNT" -eq 0 ]; then
        echo -e "✅ 쿠버네티스 내부 로드밸런서 객체 완전 삭제 확인!"
        # 쿠버네티스 객체는 지워졌어도 AWS API 반영 속도를 고려해 안전하게 30초 추가 대기
        echo "안전한 권한 회수를 위해 30초 추가 대기합니다..."
        sleep 30
        break
    fi
    echo "대기 중... 남은 LoadBalancer 관련 리소스 수: $LB_COUNT (시도: $i/30)"
    sleep 10
done

# 4. eksctl IAM 스택 삭제
echo -e "\n[Step 4] 컨트롤러 IAM 권한(유령 CF 스택) 회수 중..."
if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace karpenter --name karpenter 2>/dev/null | grep -q karpenter; then
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name karpenter --namespace karpenter
fi

if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace kube-system --name aws-load-balancer-controller 2>/dev/null | grep -q aws-load-balancer-controller; then
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name aws-load-balancer-controller --namespace kube-system
fi

echo -e "\n${GREEN}===========================================================${NC}"
echo -e "🎉 정리가 완벽하게 끝났습니다! 이제 CloudFormation에서 스택을 삭제해 주세요.${NC}"
echo -e "${GREEN}===========================================================${NC}"