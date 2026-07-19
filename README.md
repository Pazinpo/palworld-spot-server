# palworld-spot-server

친구들과 24시간 상시 접속하는 팰월드(Palworld) 서버를, AWS 스팟 인스턴스로
비용을 아끼면서도 플레이 중 끊김은 최소화하도록 구성한 Terraform 인프라.

- 서버 본체: EC2 스팟 인스턴스 (`t3.large`, persistent + stop 방식)
- 세이브 데이터: 루트 볼륨과 분리된 EBS 볼륨 (인스턴스 교체돼도 유지)
- 스팟 중단 대응: EventBridge + Lambda가 접속자 유무를 확인해서
  - 0명이면 방치 (나중에 스팟 재확보되면 자동 재기동)
  - 접속자가 있으면 온디맨드 인스턴스로 즉시 대체 기동 (EBS/EIP 그대로 이전)
- CloudWatch로 `CPUCreditBalance` 모니터링 (렉의 주 원인인 CPU 크레딧 고갈 감지)

아키텍처 상세 설명은 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 참고.

## 사전 준비물

- Terraform >= 1.7
- AWS CLI v2, 자격증명 설정 완료 (`aws sts get-caller-identity` 로 확인)
- 배포 대상 AWS 계정에 기본 VPC(default VPC)가 있어야 함
  (`aws ec2 describe-vpcs --filters Name=is-default,Values=true`)

## 사용법

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 를 열어서 admin_password 등 값을 채운다

terraform init
terraform plan
terraform apply
```

적용이 끝나면 출력되는 `server_public_ip` 가 친구들에게 공유할 접속 IP다.
팰월드 클라이언트에서 `서버 직접 접속` 메뉴로 이 IP와 포트 8211을 입력하면 된다.

관리자 접속(셸)은 SSH 대신 SSM Session Manager를 쓴다.

```bash
terraform output ssm_session_command
# 출력된 명령을 그대로 실행하면 인스턴스에 접속된다
aws ssm start-session --target <instance-id> --region ap-northeast-2
```

## 인프라 제거

```bash
cd terraform
terraform destroy
```

세이브 데이터 EBS 볼륨(`aws_ebs_volume.palworld_data`)은
`prevent_destroy = true` 로 보호되어 있어 `destroy`만으로는 지워지지 않는다.
정말로 삭제하려면 `terraform/ebs.tf`에서 해당 lifecycle 블록을
지운 뒤 다시 `destroy`를 실행해야 한다.

## 디렉터리 구조

```
terraform/    EC2, EBS, 보안그룹, EventBridge, Lambda, CloudWatch 등 IaC 정의
scripts/      install-palworld.sh - User Data로 실행되는 서버 설치 스크립트
lambda/       스팟 중단 감지 + 온디맨드 대체 기동 로직 (Python)
docs/         ARCHITECTURE.md - 아키텍처 설명
```

## 알아두어야 할 한계

- 스팟 중단 예고는 2분 전에 오므로, 접속자가 있을 때 온디맨드로
  전환하는 과정에서 짧은 접속 끊김이 발생할 수 있다.
- Lambda가 온디맨드로 대체 기동한 뒤에는 Terraform state가 옛 인스턴스를
  가리키게 된다. 안정화된 뒤 `terraform apply -replace="aws_instance.palworld"`
  로 재조정이 필요하다. 자세한 내용은
  [docs/ARCHITECTURE.md의 "한계 / 운영 노트"](docs/ARCHITECTURE.md#한계--운영-노트) 참고.
- 팰월드 REST API로 접속자 수를 확인하는 과정이 실패하면(응답 지연 등)
  안전 우선으로 "접속자가 있다"고 간주하고 온디맨드로 전환한다.
