#!/bin/bash
# EKS Infrastructure Full Verification Script
set -u

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}===========================================================${NC}"
echo -e "🔎 EKS 인프라 및 애플리케이션 통합 진단을 시작합니다..."
echo -e "${GREEN}===========================================================${NC}"

# 클러스터 및 환경 변수 자동 설정
CLUSTER_NAME=$(aws eks list-clusters --query "clusters[0]" --output text 2>/dev/null)
if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "None" ]]; then
    echo -e "${RED}❌ EKS 클러스터를 찾을 수 없습니다.${NC}"
    exit 1
fi
SERVICE_NAME=${CLUSTER_NAME%-cluster}

# 사용자로부터 네임스페이스 입력받기 (CFN의 AppEnvironment 파라미터 대응)
read -p "▶ 검증할 앱의 네임스페이스 환경을 입력하세요 (dev/stg/prod) [기본값: dev]: " INPUT_NS
APP_NS=${INPUT_NS:-"dev"}
APP_NAME="${SERVICE_NAME}-app"

echo -e "✅ 검증 대상 클러스터: ${YELLOW}$CLUSTER_NAME${NC}"
echo -e "✅ 검증 대상 네임스페이스: ${YELLOW}$APP_NS${NC}\n"

# ---------------------------------------------------------
# 1. 노드 및 VPC CNI 상태 체크
# ---------------------------------------------------------
echo -e "${GREEN}>>> [1/7] Node & VPC CNI Status...${NC}"
kubectl get nodes

PREFIX_DELEGATION=$(kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PREFIX_DELEGATION")].value}')
WARM_TARGET=$(kubectl get daemonset aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WARM_PREFIX_TARGET")].value}')

if [[ "$PREFIX_DELEGATION" == "true" && "$WARM_TARGET" == "1" ]]; then
    echo -e "✅ VPC CNI Prefix Delegation is ON (Target: 1)"
else
    echo -e "${RED}❌ VPC CNI 설정이 올바르지 않습니다. (Prefix Delegation: $PREFIX_DELEGATION)${NC}"
fi

# ---------------------------------------------------------
# 2. Karpenter 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [2/7] Karpenter Status...${NC}"
KARPENTER_POD=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KARPENTER_POD" == "Running" ]]; then
    echo -e "✅ Karpenter Pod is Running"
    kubectl get nodepool,ec2nodeclass
else
    echo -e "${RED}❌ Karpenter Pod is not running ($KARPENTER_POD)${NC}"
fi

# ---------------------------------------------------------
# 3. AWS Load Balancer Controller 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [3/7] AWS ALB Controller Status...${NC}"
ALB_POD=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$ALB_POD" == "Running" ]]; then
    echo -e "✅ ALB Controller Pod is Running"
else
    echo -e "${RED}❌ ALB Controller Pod is not running ($ALB_POD)${NC}"
fi

# ---------------------------------------------------------
# 4. 모니터링 스택 (Grafana/Prometheus) 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [4/7] Monitoring Stack (Grafana)...${NC}"
GRAFANA_URL=$(kubectl get svc -n monitoring monitoring-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "$GRAFANA_URL" ]]; then
    echo -e "✅ Grafana LoadBalancer Assigned: http://$GRAFANA_URL"
else
    echo -e "${YELLOW}⚠️ Grafana LoadBalancer is provisioning or missing.${NC}"
fi

# ---------------------------------------------------------
# 5. ArgoCD 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [5/7] ArgoCD Status...${NC}"
ARGOCD_URL=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "$ARGOCD_URL" ]]; then
    echo -e "✅ ArgoCD LoadBalancer Assigned: https://$ARGOCD_URL"
else
    echo -e "${YELLOW}⚠️ ArgoCD LoadBalancer is provisioning or missing.${NC}"
fi

# ---------------------------------------------------------
# 6. Metrics Server & HPA 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [6/7] Metrics Server & HPA...${NC}"
METRICS_POD=$(kubectl get pods -n kube-system -l k8s-app=metrics-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$METRICS_POD" == "Running" ]]; then
    echo -e "✅ Metrics Server is Running"
else
    echo -e "${RED}❌ Metrics Server is not running ($METRICS_POD)${NC}"
fi

kubectl get hpa ${APP_NAME}-hpa -n ${APP_NS} 2>/dev/null || echo -e "${RED}❌ HPA not found in namespace ${APP_NS}${NC}"

# ---------------------------------------------------------
# 7. Sample App (Ingress) 체크
# ---------------------------------------------------------
echo -e "\n${GREEN}>>> [7/7] Sample App & Ingress Status (${APP_NS})...${NC}"
APP_PODS=$(kubectl get pods -n ${APP_NS} -l app=${APP_NAME} | grep -c "Running" || echo 0)
echo -e "✅ Running App Pods: $APP_PODS"

INGRESS_URL=$(kubectl get ingress ${SERVICE_NAME}-ingress -n ${APP_NS} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [[ -n "$INGRESS_URL" ]]; then
    echo -e "✅ Sample App Ingress Assigned: http://$INGRESS_URL"
else
    echo -e "${YELLOW}⚠️ Ingress ALB is provisioning or missing.${NC}"
fi

echo -e "\n${GREEN}===========================================================${NC}"
echo -e "🎉 검증이 완료되었습니다!"
echo -e "${GREEN}===========================================================${NC}"