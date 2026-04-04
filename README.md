## 🏗️ 시스템 아키텍처 (Architecture)

* **VPC:** 3-Tier 계층 구조 (Public / Private App / Private DB)
* **High Availability:** 2개의 가용 영역(AZ)에 걸친 서브넷 2중화 및 NAT Gateway 배치
* **Security:** IAM Role 기반의 EKS Access Entry 권한 체계 및 SSM 관리 환경
* **Scaling:** Karpenter(v1.2.0)를 통한 JIT(Just-in-Time) 노드 프로비저닝 환경 구축

---

## 🛠️ 기술 스택 (Tech Stack)

| Category | Technology | Version | Remark |
| :--- | :--- | :--- | :--- |
| **Platform** | Amazon EKS | **v1.34** | 최신 안정화 버전 적용 |
| **IaC** | AWS CloudFormation | Standard | YAML 기반 전체 리소스 자동화 |
| **Auto Scaling** | Karpenter | **v1.2.0** | NodePool 방식의 차세대 스케일러 |
| **Ingress** | AWS Load Balancer Controller | Latest | ALB 기반 L7 라우팅 지원 |
| **Monitoring** | Prometheus & Grafana | Helm Stack | Step 11 설치 완료 |
| **CD Engine** | ArgoCD | Stable | **Step 12 검증 진행 중** |

---

## 📍 인프라 구축 로드맵 (Step 1 ~ 11 완료)

### Phase 1: 클러스터 기반 및 보안 강화 (Completed)
1.  **[Step 1-2] CLI Ecosystem:** AWS CLI v2, `kubectl`, `eksctl`, `helm` 등 필수 도구 자동 배치.
2.  **[Step 3-4] Cluster Sync:** EKS API 서버 `ACTIVE` 상태 감시 및 `Kubeconfig` 환경 변수(Root/User) 자동 등록.
3.  **[Step 5-7] Identity Management:** OIDC Provider 연결 및 Karpenter/ALB Controller를 위한 IRSA(IAM Role for Service Accounts) 구축.

### Phase 2: 지능형 엔진 및 관제 시스템 배포 (In Progress)
4.  **[Step 8-9] Scaling Engine:** 전용 네임스페이스 격리 및 Karpenter v1.2.0 엔진 기동.
5.  **[Step 10] Traffic Entry:** AWS Load Balancer Controller 설치를 통한 Ingress(ALB) 연동 준비 완료.
6.  **[Step 11] Full-Stack Monitoring:** Prometheus와 Grafana 배포 완료 (Grafana 초기 PW: `admin`).

### Phase 3: GitOps 및 노드 최적화 (Validation)
7.  **[Step 12] ArgoCD Deployment:** CRD 크기 제한 문제 해결을 위한 `--server-side` 옵션 적용 및 설치 검증 중.
8.  **[Step 13-14] Finalizing:** ArgoCD 외부 접속 설정 및 실제 워크로드 수용을 위한 Karpenter NodePool 최종 활성화.

---

## 📈 현재 상태 및 향후 계획

| 단계 | 상태 | 주요 마일스톤 |
| :--- | :---: | :--- |
| **Phase 1** | **Completed** | VPC/EKS 인프라 기초 및 보안 권한 확보 |
| **Phase 2** | **Completed** | ALB/모니터링 설치 완료 |
| **Phase 3** | **Testing** | **ArgoCD 검증(Step 12)** 및 NodePool 활성화 |

> **⚠️ 기술적 특이사항 (Troubleshooting):**
> ArgoCD 설치 시 CRD 용량 초과로 인한 에러를 방지하기 위해 `kubectl apply --server-side` 플래그를 도입하여 검증 중입니다.