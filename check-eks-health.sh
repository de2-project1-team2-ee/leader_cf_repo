#!/bin/bash
# EKS Cluster Health Checker
# CFN을 통해서 생성 된 설정들의 유효성을 체크합니다.
set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# [추가] 서비스 이름 입력 받기
echo -e "${GREEN}입력하신 서비스 이름에 '-cluster'를 붙여 점검을 시작합니다.${NC}"

## Before
#read -p "서비스 이름을 입력하세요 (예: de-camping-msa): " INPUT_SERVICE_NAME
## 입력값이 없을 경우 기본값 설정 또는 종료
#if [[ -z "$INPUT_SERVICE_NAME" ]]; then
#    echo -e "${RED}❌ 서비스 이름이 입력되지 않았습니다. 종료합니다.${NC}"
#    exit 1
#fi
#
## 클러스터명 생성 (CFN 명명 규칙 반영)
#CLUSTER_NAME="${INPUT_SERVICE_NAME}-cluster"
#echo -e "🔍 점검 대상 클러스터: ${GREEN}$CLUSTER_NAME${NC}\n"
###

## After
# 현재 리전에 있는 첫 번째 EKS 클러스터 이름을 가져옵니다.
CLUSTER_NAME=$(aws eks list-clusters --query "clusters[0]" --output text)
# 클러스터를 찾지 못했을 경우 예외 처리
if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "None" ]]; then
    echo -e "${RED}❌ EKS 클러스터를 찾을 수 없습니다. CloudFormation 배포 상태를 확인하세요.${NC}"
    exit 1
fi
echo -e "🔍 Detected Cluster: ${GREEN}$CLUSTER_NAME${NC}\n"
###

echo -e "${GREEN}>>> [1/6] Checking Node Status...${NC}"
READY_NODES=$(kubectl get nodes --no-headers | grep -c "Ready" || echo 0)
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
if [ "$READY_NODES" -eq "$TOTAL_NODES" ] && [ "$TOTAL_NODES" -gt 0 ]; then
    echo -e "✅ Nodes are Healthy: ($READY_NODES/$TOTAL_NODES)"
else
    echo -e "${RED}❌ Node Issue Detected! Ready: $READY_NODES, Total: $TOTAL_NODES${NC}"
fi

# [추가] 네임스페이스 존재 여부 체크
echo -e "\n${GREEN}>>> [2/6] Checking Required Namespaces...${NC}"
REQUIRED_NS=("dev" "stg" "prod" "monitoring" "argocd" "karpenter" "kube-system")
MISSING_NS=()

for NS in "${REQUIRED_NS[@]}"; do
    if kubectl get namespace "$NS" &>/dev/null; then
        echo -e "✅ Namespace '$NS': Found"
    else
        echo -e "${RED}❌ Namespace '$NS': NOT FOUND${NC}"
        MISSING_NS+=("$NS")
    fi
done

echo -e "\n${GREEN}>>> [3/6] Checking System Pods (Critical)...${NC}"
COMPONENTS=("karpenter" "aws-load-balancer-controller" "argocd-server")
for COMP in "${COMPONENTS[@]}"; do
    # 특정 컴포넌트가 어느 네임스페이스에 있든 상관없이 Running 상태인지 체크
    STATUS=$(kubectl get pods -A | grep "$COMP" | awk '{print $4}' | grep "Running" | head -n 1 || echo "NotRunning")
    if [[ "$STATUS" == "Running" ]]; then
        echo -e "✅ $COMP: Running"
    else
        echo -e "${RED}❌ $COMP: Status is $STATUS${NC}"
    fi
done

echo -e "\n${GREEN}>>> [4/6] Checking OIDC & IRSA...${NC}"
#CLUSTER_NAME="de-camping-msa-cluster" # 실제 클러스터명으로 확인 필요
#OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

### [Before]
#OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text 2>/dev/null | cut -d '/' -f 5 || echo "")
#
#if [[ -z "$OIDC_URL" ]]; then
#    echo -e "${RED}❌ 클러스터 '$CLUSTER_NAME'을 찾을 수 없습니다. 이름을 확인해주세요.${NC}"
#else
#  IAM_OIDC=$(aws iam list-open-id-connect-providers | grep "$OIDC_URL" || true)
#  if [[ -n "$IAM_OIDC" ]]; then
#      echo -e "✅ OIDC Provider Linked"
#  else
#      echo -e "${RED}❌ OIDC Provider NOT Found!${NC}"
#  fi
#fi

###
### [After]
OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query "cluster.identity.oidc.issuer" --output text 2>/dev/null | cut -d '/' -f 5 || echo "")

if [[ -z "$OIDC_URL" ]]; then
    echo -e "${RED}❌ 클러스터 '$CLUSTER_NAME' 정보를 가져오는데 실패했습니다.${NC}"
else
    IAM_OIDC=$(aws iam list-open-id-connect-providers | grep "$OIDC_URL" || true)
    if [[ -n "$IAM_OIDC" ]]; then
        echo -e "✅ OIDC Provider Linked"
    else
        echo -e "${RED}❌ OIDC Provider NOT Found!${NC}"
    fi
fi
###

echo -e "\n${GREEN}>>> [5/6] Checking Karpenter NodePool...${NC}"
if kubectl get nodepools.karpenter.sh default &>/dev/null; then
    echo -e "✅ Karpenter NodePool 'default' is present"
else
    echo -e "${RED}❌ Karpenter NodePool NOT found${NC}"
fi

echo -e "\n${GREEN}>>> [6/6] Checking ArgoCD Access...${NC}"
ARGOCD_SVC_TYPE=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.type}' 2>/dev/null || echo "NotFound")
if [[ "$ARGOCD_SVC_TYPE" != "NotFound" ]]; then
    echo -e "✅ ArgoCD Service Type: $ARGOCD_SVC_TYPE"
else
    echo -e "${RED}❌ ArgoCD Service NOT found${NC}"
fi

echo -e "\n${GREEN}>>> Health Check Completed!${NC}"