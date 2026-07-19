# palworld-spot-server

친구 3~4명이랑 상시 켜두고 노는 팰월드 서버를 온디맨드로 24시간 돌리면
매달 요금이 꽤 나온다. 그래서 스팟 인스턴스로 돌리되, 스팟이 회수될 때
누가 접속해 있으면 자동으로 온디맨드 인스턴스로 넘어가도록 만들어봤다.
세이브랑 접속 IP는 그대로 유지되니까 친구들 입장에서는 재접속 한 번이면
끝난다.

구성 요약:

- 서버 본체는 EC2 스팟 인스턴스(`t3.large`). `persistent + stop` 옵션을 써서
  아무도 없을 땐 그냥 정지시켰다가 스팟 용량이 다시 생기면 AWS가 알아서
  재기동하게 둔다.
- 세이브 데이터는 루트 볼륨과 분리한 EBS 볼륨에 저장. 인스턴스가 바뀌어도
  이 볼륨만 옮기면 되니까 데이터는 안전하다.
- EventBridge가 스팟 중단 2분 전 예고를 잡아서 Lambda를 깨운다. Lambda는
  SSM으로 접속자 수를 확인하고, 사람이 있으면 온디맨드 인스턴스를 새로
  띄운 뒤 EBS 볼륨이랑 Elastic IP를 그쪽으로 옮긴다.
- CPUCreditBalance를 CloudWatch로 감시한다. t3 계열이라 크레딧 떨어지면
  렉이 심해지는데, 미리 알람 받으려고 넣었다.

아키텍처 자세한 내용이랑 왜 이렇게 짰는지는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)에 정리해뒀다.

## 준비물

- Terraform >= 1.7
- AWS CLI v2 (`aws sts get-caller-identity`로 로그인 확인)
- 기본 VPC가 있는 계정 (거의 다 있을 텐데, 없으면 `aws ec2 describe-vpcs
  --filters Name=is-default,Values=true`로 확인)

## 배포

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# admin_password 등 값 채우기

terraform init
terraform plan
terraform apply
```

apply가 끝나면 나오는 `server_public_ip`를 친구들한테 던져주면 된다.
팰월드에서 서버 직접 접속으로 이 IP + 8211 포트 입력.

SSH는 안 열어놨고, 관리자 접속은 SSM Session Manager로 한다.

```bash
terraform output ssm_session_command   # 이 명령 그대로 실행
```

## 지우고 싶을 때

```bash
cd terraform
terraform destroy
```

세이브 볼륨은 실수로 날아가지 않게 `prevent_destroy`를 걸어놔서 이것만으로는
안 지워진다. 진짜 지우려면 `terraform/ebs.tf`에서 그 lifecycle 블록 지우고
다시 destroy 해야 한다.

## 구조

```
terraform/    EC2, EBS, 보안그룹, EventBridge, Lambda, CloudWatch 정의
scripts/      install-palworld.sh - User Data로 도는 서버 설치 스크립트
lambda/       스팟 중단 감지 -> 온디맨드 전환 로직 (Python)
docs/         아키텍처 설명
```

## 한계점

- 스팟 중단 예고는 항상 2분 전이라, Lambda가 그 안에 전환을 끝내야 한다.
  네트워크나 API가 좀 느려지면 짧게 끊길 수 있다.
- Lambda가 온디맨드로 넘긴 뒤에는 Terraform state가 죽은 인스턴스를 계속
  물고 있게 된다. `terraform apply -replace="aws_instance.palworld"`로
  정리해줘야 함 - 자세한 건 [ARCHITECTURE.md](docs/ARCHITECTURE.md#한계--운영-노트) 참고.
- 접속자 수 확인이 애매하게 실패하면(REST API 무응답 등) 그냥 "사람 있다"고
  치고 온디맨드로 넘긴다. 괜히 전환했다가 낭비되는 비용보다 끊기는 게 더
  나쁘다고 판단해서.
- 온디맨드로 넘어간 뒤 다시 스팟으로 자동 복귀하는 로직은 없다. 지금은
  수동으로 정리하는 걸로 두고 있고, 나중에 여유 생기면 스케줄러로 자동화할
  생각.
