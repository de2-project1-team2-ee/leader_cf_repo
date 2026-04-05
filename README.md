# 🏕️ 2e-server-cfn-0.5.0.yaml
## 인프라 및 K8S 구축 구조화 문서

### 1. 인프라 구성 요소 및 주요 기능

해당 CloudFormation 템플릿은 고가용성 네트워크 구성, 보안 격리, 그리고 EKS 클러스터 기반의 컨테이너 오케스트레이션 환경을 한 번에 배포하도록 설계되었습니다.

| 구분 | 리소스 명칭 (Type) | 주요 기능 및 역할 |
| :--- | :--- | :--- |
| **네트워크** | MainVPC | `10.0.0.0/20` 대역을 사용하는 전체 시스템의 최상위 네트워크 격리 공간 |
| | PublicSubnets (1, 2) | 인터넷 게이트웨이(IGW)와 연결되어 외부 접근이 가능한 영역 (ALB, Bastion, NAT GW 위치) |
| | PrivateAppSubnets (1, 2) | NAT GW를 통해 외부 인터넷으로 나갈 수는 있으나, 외부에서 직접 접근할 수 없는 영역 (EKS Node, 애플리케이션 Pod 위치) |
| | PrivateDBSubnets (1, 2) | 외부 인터넷과 완전히 단절된 **격리된 라우팅(Isolated)** 영역 (데이터베이스 전용) |
| **보안** | Security Groups (SG) | Bastion(SSH), ALB(HTTP), EKS Node(VPC 내부 통신), DB(3306 포트) 간의 트래픽 접근 제어 |
| **권한 (IAM)** | Bastion / EKS Roles | Bastion 서버의 EKS 관리 권한(Access Entry), EKS 노드의 CNI 및 컨테이너 레지스트리 접근 권한 부여 |
| **컴퓨팅** | Bastion Server (EC2) | 프라이빗망(EKS, DB)에 접근하고 K8S 클러스터를 초기화하는 관리형 접속 서버 (최신 공식 CLI 도구 자동 탑재) |
| | EKS Cluster & NodeGroup | 애플리케이션이 배포될 K8S 컨트롤 플레인 및 초기 워커 노드 그룹 (Private Subnet에 배치) |

<br>

### 2. CloudFormation 실행 및 프로비저닝 순서 (Sequential Lab Roadmap)

AWS CloudFormation을 통해 스택이 배포될 때, 리소스 간의 의존성(`DependsOn`) 및 참조(`Ref`, `GetAtt`)에 따라 다음 순서로 인프라가 구성됩니다.

#### Phase 1: 기본 네트워크 및 권한 프로비저닝 (AWS 계층)
1. **VPC 및 Subnet 생성**: 메인 VPC와 6개의 서브넷(Public 2, Private App 2, Private DB 2)이 각 가용 영역(AZ)에 생성됩니다.
2. **게이트웨이 및 라우팅 설정**: 인터넷 게이트웨이(IGW)와 NAT 게이트웨이가 구성되고, 라우트 테이블을 통해 트래픽 흐름이 정의됩니다. (DB 서브넷은 외부 라우팅 제외)
3. **IAM Role 및 Security Group 생성**: 각 인스턴스와 클러스터가 사용할 권한(Role)과 방화벽 규칙(SG)이 생성됩니다.

#### Phase 2: 컴퓨팅 노드 및 클러스터 프로비저닝 (AWS 계층)
4. **EKS Cluster 생성**: 컨트롤 플레인이 배포됩니다.
5. **Private App NodeGroup 생성**: EKS 클러스터 내부에서 파드가 실행될 고정 워커 노드가 구성됩니다.
6. **Bastion Server 생성**: 관리형 EC2가 Public Subnet에 띄워지며, `UserData` 스크립트를 통해 자동으로 내부 K8S 설정이 시작됩니다.

#### Phase 3: 클러스터 내부 구성 (K8S 계층 - Bastion UserData 자동화)
Bastion 서버가 구동되면서 공식 릴리즈된 최신 CLI 소프트웨어들을 다운로드하여 내부적으로 다음 작업을 순차 실행합니다.

| 순서 | 작업 명칭 | 상세 설명 및 목적 |
| :---: | :--- | :--- |
| **1** | **필수 CLI 도구 설치** | AWS CLI, `kubectl`, `argocd`, `eksctl`, `helm` 등 공식 바이너리를 설치하여 관리 환경 구축 |
| **2** | **EKS 상태 검증 및 연결** | 클러스터가 `ACTIVE` 상태가 될 때까지 대기 후, Kubeconfig를 업데이트하여 제어권 획득 |
| **3** | **네트워크 최적화 (VPC CNI)** | `ENABLE_PREFIX_DELEGATION=true`를 적용하여 노드당 할당 가능한 Pod의 개수(IP 대역) 한도를 대폭 확장 |
| **4** | **보안 및 인증 (IRSA)** | OIDC Provider를 연결하고, Karpenter 및 ALB Controller가 AWS 리소스를 제어할 수 있도록 IAM 계정과 K8S 서비스 어카운트 연동 |
| **5** | **K8S 필수 Add-on 배포** | Helm을 활용해 Karpenter(동적 노드 프로비저닝), AWS Load Balancer Controller(Ingress/ALB 연동), Prometheus & Grafana(모니터링) 배포 |
| **6** | **GitOps 환경 (ArgoCD)** | ArgoCD 배포 및 초기 비밀번호 해시 자동 주입, 외부 접속용 LoadBalancer 설정 |
| **7** | **Karpenter NodePool 생성** | 워커 노드의 동적 확장을 위해 EC2 Spot 인스턴스 중심의 자원 할당 규칙(NodePool, EC2NodeClass) 적용 |
| **8** | **Metrics Server 및 앱 배포** | HPA(수평 확장) 작동을 위한 Metrics Server 설치 후, 동적 네임스페이스 환경에 Nginx 기반의 샘플 WAS(Deployment, Service, HPA, Ingress) 일괄 배포 |

<br>

# 🩺 EKS 인프라 및 애플리케이션 통합 진단 스크립트 (`check-eks-health.sh`)

## 1. 스크립트 개요
이 스크립트는 AWS EKS 클러스터와 그 내부에 배포된 주요 애드온(Karpenter, ALB Controller 등) 및 애플리케이션의 상태를 한 번에 점검하는 **통합 상태 확인(Health Check) 도구**입니다. 클러스터 이름을 자동으로 감지하고, 사용자가 지정한 네임스페이스 환경을 기준으로 전체적인 검증을 수행합니다.

## 2. 실행 방법
터미널에서 스크립트가 위치한 경로로 이동한 후 아래 명령어를 실행합니다.

* **실행 명령어:** `sh ./check-eks-health.sh`
* **실행 흐름:** 1. AWS CLI를 통해 현재 환경의 EKS 클러스터 이름을 자동으로 찾습니다.
    2. 사용자에게 검증할 애플리케이션의 네임스페이스(`dev`, `stg`, `prod` 등)를 묻는 프롬프트가 나타납니다.
    3. 원하는 환경을 입력하거나, 그냥 엔터를 치면 기본값인 `dev` 환경을 타겟으로 검증을 시작합니다.

---

## 3. 주요 점검 항목 및 기능 (7단계 검증 로직)

스크립트는 총 7개의 핵심 인프라 구성 요소를 순차적으로 확인합니다.

| 단계 | 점검 항목 | 상세 내용 및 검증 기준 |
| :---: | :--- | :--- |
| **1** | **Node & VPC CNI 상태** | K8S 워커 노드 목록을 출력하고, `aws-node` 데몬셋의 환경 변수를 확인하여 **Prefix Delegation 기능이 활성화(`true`)**되어 있는지, 여유 IP 풀(`WARM_PREFIX_TARGET`)이 `1`로 최적화되어 있는지 점검합니다. |
| **2** | **Karpenter 상태** | 동적 노드 확장을 담당하는 `karpenter` 파드가 `Running` 상태인지 확인하고, 설정된 `nodepool` 및 `ec2nodeclass` 리소스 내역을 출력합니다. |
| **3** | **AWS ALB Controller 상태** | `kube-system` 네임스페이스 내의 AWS Load Balancer Controller 파드가 정상적으로 구동(`Running`)되어 Ingress(ALB) 생성 준비가 되었는지 확인합니다. |
| **4** | **모니터링 스택 (Grafana)** | `monitoring` 네임스페이스의 Grafana 서비스에 외부 접속을 위한 **LoadBalancer Hostname(URL)이 정상적으로 할당**되었는지 점검합니다. |
| **5** | **ArgoCD 상태** | `argocd` 네임스페이스의 ArgoCD 서버 서비스에 외부 접속용 LoadBalancer URL이 정상적으로 할당되었는지 점검합니다. |
| **6** | **Metrics Server & HPA** | 파드 자동 확장을 위한 필수 수집기인 `metrics-server` 파드의 구동 상태를 확인하고, 타겟 네임스페이스에 애플리케이션용 **HPA(Horizontal Pod Autoscaler)** 객체가 잘 생성되었는지 확인합니다. |
| **7** | **Sample App & Ingress 상태** | 지정된 네임스페이스 내에 애플리케이션 파드들이 `Running` 상태인지 개수를 확인하고, 최종적으로 연결된 **Ingress ALB의 접속 주소(http://...)가 발급되었는지 점검**합니다. |

---

## 2. `clean-up.sh` (v0.5.1 - 비동기 대기 로직 강화 버전)
이전 스크립트의 문제점(AWS 로드밸런서가 지워지기 전에 IAM 권한이 먼저 삭제되어 VPC가 지워지지 않는 현상)을 해결하기 위해 **완전 자동화 및 비동기 대기 로직이 추가된 개선 버전**입니다.

### 🚀 실행 방법
서비스 이름을 직접 찾아서 실행하므로 별도의 파라미터가 필요 없습니다.
* `sh ./clean-up.sh`

### ⚙️ 주요 기능 및 동작 순서
| 단계 | 기능 명칭 | 상세 설명 |
| :---: | :--- | :--- |
| **1** | **클러스터 자동 감지** | 사용자 입력 없이 AWS CLI를 사용하여 현재 계정/리전에 있는 EKS 클러스터 이름과 리전을 **자동으로 탐색**합니다. |
| **2** | **컴퓨팅 및 네트워크 자원 삭제** | Karpenter 리소스(`nodepool`, `ec2nodeclass`) 및 로드밸런서를 유발하는 서비스(`ingress`, `argocd-server`, `grafana`)를 일괄 삭제 트리거합니다. |
| **3** | **비동기 삭제 완벽 대기 (핵심)** | 최대 5분 동안 루프를 돌며 쿠버네티스 내부에 로드밸런서 객체가 남아있는지 확인합니다. 객체가 완전히 사라진 후에도 AWS API 반영 속도를 고려해 **30초를 추가로 대기하는 안전장치**가 적용되어 있습니다. |
| **4** | **IAM 역할 스택 안전 삭제** | 로드밸런서가 완전히 파괴된 것이 보장된 상태에서, 컨트롤러 IAM 권한(`karpenter`, `aws-load-balancer-controller`)을 안전하게 회수합니다. |