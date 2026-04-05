#!/bin/bash
# EKS Cluster Health Checker
# CFN을 통해서 생성 된 설정들의 유효성을 체크합니다.
set -u

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

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
CLUSTER_NAME="de-camping-msa-cluster" # 실제 클러스터명으로 확인 필요
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
IAM_OIDC=$(aws iam list-open-id-connect-providers | grep "$OIDC_URL" || true)
if [[ -n "$IAM_OIDC" ]]; then
    echo -e "✅ OIDC Provider Linked"
else
    echo -e "${RED}❌ OIDC Provider NOT Found!${NC}"
fi

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