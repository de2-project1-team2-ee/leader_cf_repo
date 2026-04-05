#!/bin/bash

# ==============================================================================
# EKS Cluster Clean-up Script (v0.5.0 반영)
# CFN 템플릿의 변경점(Grafana LB, 동적 환경 등)을 모두 반영하여 잔여 리소스를 삭제합니다.
# 실행 명령어: sh ./clean-up.sh
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}===========================================================${NC}"
echo -e "🧹 EKS 내부 리소스 자동 정리를 시작합니다..."
echo -e "${GREEN}===========================================================${NC}"

# 1. 대상 클러스터 및 Region 자동 탐색 (check-eks-health 로직 차용)
echo "[Step 1] 클러스터 및 Region 정보 자동 추출 중..."
CLUSTER_NAME=$(aws eks list-clusters --query "clusters[0]" --output text)

if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "None" ]]; then
    echo -e "${RED}❌ EKS 클러스터를 찾을 수 없습니다. 이미 삭제되었거나 권한이 없습니다.${NC}"
    exit 1
fi

# CFN 명명 규칙을 역산하여 ServiceName 자동 추출
SERVICE_NAME=${CLUSTER_NAME%-cluster}

# IMDSv2를 통한 안전한 Region 자동 추출
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [ -n "$TOKEN" ]; then
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
else
    REGION=$(aws configure get region)
fi

echo -e "✅ 타겟 ServiceName: ${GREEN}$SERVICE_NAME${NC}"
echo -e "✅ 타겟 클러스터: ${GREEN}$CLUSTER_NAME${NC}"
echo -e "✅ 타겟 Region: ${GREEN}$REGION${NC}"
echo "-----------------------------------------------------------"

# 2. Karpenter 리소스 삭제 (EC2 인스턴스 자동 반납 유도)
echo "[Step 2] Karpenter NodePool 및 EC2NodeClass 삭제 중 (EC2 반납)..."
kubectl delete nodepool default --timeout=60s 2>/dev/null || echo "▶ NodePool이 이미 없거나 삭제되었습니다."
kubectl delete ec2nodeclass default --timeout=60s 2>/dev/null || echo "▶ EC2NodeClass가 이미 없거나 삭제되었습니다."

# 3. AWS ALB/NLB 삭제 유도 (매우 중요: CFN v0.5.0 업데이트 내역 반영)
echo "[Step 3] 외부 LoadBalancer 리소스(CLB/ALB) 3종 삭제 유도 중..."
# 3-1. App Ingress (ALB) - 네임스페이스 상관없이 싹쓸이
kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || echo "▶ Ingress가 이미 없거나 삭제되었습니다."
# 3-2. ArgoCD (CLB)
kubectl delete svc argocd-server -n argocd --timeout=60s 2>/dev/null || echo "▶ ArgoCD Service가 이미 없거나 삭제되었습니다."
# 3-3. [핵심 추가] Grafana (CLB) - 삭제하지 않으면 VPC 지연 발생
kubectl delete svc monitoring-stack-grafana -n monitoring --timeout=60s 2>/dev/null || echo "▶ Grafana Service가 이미 없거나 삭제되었습니다."

# 4. eksctl이 생성한 IAM Service Account(유령 CF 스택) 삭제
echo "[Step 4] eksctl CF 스택 삭제 중 (약 1~2분 소요)..."

if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace karpenter --name karpenter 2>/dev/null | grep -q karpenter; then
    echo "▶ Karpenter IAM Service Account 삭제 진행..."
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name karpenter --namespace karpenter
else
    echo "▶ Karpenter IAM Service Account가 이미 존재하지 않습니다."
fi

if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace kube-system --name aws-load-balancer-controller 2>/dev/null | grep -q aws-load-balancer-controller; then
    echo "▶ ALB Controller IAM Service Account 삭제 진행..."
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name aws-load-balancer-controller --namespace kube-system
else
    echo "▶ ALB Controller IAM Service Account가 이미 존재하지 않습니다."
fi

echo -e "${GREEN}===========================================================${NC}"
echo -e "🎉 [${GREEN}$SERVICE_NAME${NC}] EKS 내부 리소스 정리가 완료되었습니다!"
echo -e "AWS 콘솔에서 EC2(App Node)와 3개의 LoadBalancer가 사라졌는지 확인한 후,"
echo -e "CloudFormation 콘솔에서 메인 스택을 삭제해 주세요."
echo -e "${GREEN}===========================================================${NC}"