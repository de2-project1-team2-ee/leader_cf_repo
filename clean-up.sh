#!/bin/bash

# ==============================================================================
# EKS Cluster Clean-up Script (대화형 입력 & Region 자동 추출 지원)
# 실행 명령어
# sh ./clean-up.sh
# 위 구문 실행 후, stack 생성 당시 할당한 service 명칭 기입시,
# 스택 1: Karpenter 컨트롤러용 IAM Role 생성 스택
# 스택 2: AWS Load Balancer (ALB) 컨트롤러용 IAM Role 생성 스택
# 위에 해당되는 스택이 모두 삭제 됨.
# ==============================================================================

echo "==========================================================="
echo "🧹 EKS 내부 리소스 자동 정리를 시작합니다..."
echo "==========================================================="

# 1. ServiceName 대화형 입력 받기 (파라미터가 없으면 물어봄)
if [ -z "$1" ]; then
    read -p "▶ 삭제할 인프라의 ServiceName을 입력하세요 (엔터 시 기본값 'de-camping-msa' 적용): " INPUT_NAME
    SERVICE_NAME=${INPUT_NAME:-"de-camping-msa"}
else
    SERVICE_NAME=$1
fi

CLUSTER_NAME="${SERVICE_NAME}-cluster"

echo "✅ 선택된 ServiceName: $SERVICE_NAME"
echo "✅ 타겟 클러스터: $CLUSTER_NAME"
echo "-----------------------------------------------------------"

# 2. AWS Region 자동 추출 (IMDSv2 토큰 기반 안전한 추출 방식)
echo "[Step 1] AWS Region 정보 추출 중..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

if [ -n "$TOKEN" ]; then
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
else
    # 메타데이터 추출 실패 시 AWS CLI 기본 설정값으로 Fallback
    REGION=$(aws configure get region)
fi

if [ -z "$REGION" ]; then
    echo "❌ Region 정보를 가져올 수 없습니다. 스크립트를 종료합니다."
    exit 1
fi

echo "✅ 타겟 Region: $REGION"
echo "-----------------------------------------------------------"

# 3. Karpenter 리소스 삭제 (EC2 인스턴스 자동 반납 유도)
echo "[Step 2] Karpenter NodePool 및 EC2NodeClass 삭제 중 (EC2 반납)..."
kubectl delete nodepool --all --timeout=60s 2>/dev/null || echo "▶ NodePool이 이미 없거나 삭제되었습니다."
kubectl delete ec2nodeclass --all --timeout=60s 2>/dev/null || echo "▶ EC2NodeClass가 이미 없거나 삭제되었습니다."

# 4. AWS ALB/NLB 삭제 유도 (Ingress 및 LoadBalancer 서비스 삭제)
echo "[Step 3] 외부 LoadBalancer 리소스 삭제 유도 중..."
kubectl delete ingress --all --all-namespaces --timeout=60s 2>/dev/null || echo "▶ Ingress가 이미 없거나 삭제되었습니다."
kubectl delete svc argocd-server -n argocd --timeout=60s 2>/dev/null || echo "▶ ArgoCD Service가 이미 없거나 삭제되었습니다."

# 5. eksctl이 생성한 IAM Service Account(유령 CF 스택) 삭제
echo "[Step 4] eksctl CF 스택 삭제 중 (약 1~2분 소요)..."

# Karpenter IAM 삭제
if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace karpenter --name karpenter 2>/dev/null | grep -q karpenter; then
    echo "▶ Karpenter IAM Service Account 삭제 진행..."
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name karpenter --namespace karpenter
else
    echo "▶ Karpenter IAM Service Account가 이미 존재하지 않습니다."
fi

# ALB Controller IAM 삭제
if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --namespace kube-system --name aws-load-balancer-controller 2>/dev/null | grep -q aws-load-balancer-controller; then
    echo "▶ ALB Controller IAM Service Account 삭제 진행..."
    eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$REGION" --name aws-load-balancer-controller --namespace kube-system
else
    echo "▶ ALB Controller IAM Service Account가 이미 존재하지 않습니다."
fi

echo "==========================================================="
echo "🎉 [$SERVICE_NAME] EKS 내부 리소스 정리가 완료되었습니다!"
echo "AWS 콘솔에서 EC2(App Node)와 LoadBalancer가 사라졌는지 확인한 후,"
echo "CloudFormation 콘솔에서 메인 스택을 삭제해 주세요."
echo "==========================================================="