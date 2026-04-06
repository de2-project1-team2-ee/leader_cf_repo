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
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"

# 2. 리전 값이 비어있는지 확인 후 사용자 직접 입력 대기
if [[ -z "$REGION" || "$REGION" == "None" ]]; then
    echo -e "${YELLOW}⚠️ 리전 정보를 자동으로 찾을 수 없습니다.${NC}"
    
    # 사용자에게 입력을 요청하고 그 값을 REGION 변수에 덮어씌움
    read -p "사용할 타겟 AWS 리전을 직접 입력해 주세요 (예: us-west-1, ap-northeast-2): " REGION
    
    # 사용자가 아무것도 입력하지 않고 엔터만 쳤을 경우를 대비한 방어 로직 (Fail-fast)
    if [[ -z "$REGION" ]]; then
        echo -e "${RED}❌ 리전이 입력되지 않아 스크립트를 안전하게 종료합니다.${NC}"
        exit 1
    fi
fi

echo -e "✅ 타겟 REGION: ${GREEN}$REGION${NC}"
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
    LB_COUNT=$(kubectl get svc,ingress --all-namespaces 2>/dev/null | grep "LoadBalancer\|alb" | wc -l)
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

# 1) eksctl을 이용한 정상적인 삭제 시도 (조건문 제거)
echo "Karpenter IAM ServiceAccount 스택 삭제 중..."
eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name karpenter --namespace karpenter --wait 2>/dev/null || true

echo "AWS Load Balancer Controller IAM ServiceAccount 스택 삭제 중..."
eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name aws-load-balancer-controller --namespace kube-system --wait 2>/dev/null || true


# 2) [안전망] eksctl이 놓친 경우 AWS CLI를 통해 CloudFormation 스택 강제 삭제
echo -e "\n잔여 CloudFormation 스택 강제 정리 검증..."
aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-karpenter-karpenter" --region "$REGION" 2>/dev/null || true
aws cloudformation delete-stack --stack-name "eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-aws-load-balancer-controller" --region "$REGION" 2>/dev/null || true

# CFN 스택 삭제는 비동기이므로 잠시 대기
sleep 10

# 5. EKS 클러스터 본체 삭제 (eksctl 사용 시)
echo -e "\n[Step 5] EKS 클러스터를 완전 삭제합니다. (이 작업은 15~20분 정도 소요될 수 있습니다)"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait

echo -e "\n${GREEN}===========================================================${NC}"
echo -e "🎉 정리가 완벽하게 끝났습니다! 이제 CloudFormation에서 스택을 삭제해 주세요.${NC}"
echo -e "${GREEN}===========================================================${NC}"