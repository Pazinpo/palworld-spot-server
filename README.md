# palworld-spot-server

친구 3~4명이랑 상시 켜두고 노는 팰월드 서버를 온디맨드로 24시간 돌리면
매달 요금이 꽤 나온다. 그래서 스팟 인스턴스로 돌리되, 스팟이 회수될 때
누가 접속해 있으면 자동으로 온디맨드 인스턴스로 넘어가도록 만들어봤다.
세이브랑 접속 IP는 그대로 유지되니까 친구들 입장에서는 재접속 한 번이면
끝난다.

구성 요약:

- 서버 본체는 EC2 스팟 인스턴스(2vCPU/8GB, 기본값 `m7i-flex.large` - Free
  Plan 계정이라 `t3.large`가 막혀서 사양 동일한 걸로 바꿈). `persistent +
  stop` 옵션을 써서 아무도 없을 땐 그냥 정지시켰다가 스팟 용량이 다시
  생기면 AWS가 알아서 재기동하게 둔다.
- 세이브 데이터는 루트 볼륨과 분리한 EBS 볼륨에 저장. 인스턴스가 바뀌어도
  이 볼륨만 옮기면 되니까 데이터는 안전하다.
- EventBridge가 스팟 중단 2분 전 예고를 잡아서 Lambda를 깨운다. Lambda는
  SSM으로 접속자 수를 확인하고, 사람이 있으면 REST API로 안내 방송을
  보낸 뒤 온디맨드 인스턴스를 새로 띄우고 EBS 볼륨이랑 Elastic IP를
  그쪽으로 옮긴다.
- 패키지 설치+SteamCMD까지 미리 해둔 예비(standby) 온디맨드 인스턴스를
  정지 상태로 항상 하나 대기시켜뒀다가(15분마다 확인), 페일오버 때 그걸
  재활용해서 처음부터 새로 띄우는 것보다 전환 시간을 줄인다.
- 온디맨드로 넘어간 뒤에는 30분마다 같은 Lambda가 다시 깨서, 접속자가
  없는 틈에 스팟으로 자동 복귀를 시도한다. 스팟 용량이 아직 없으면 다음
  주기에 다시 시도.
- CPUCreditBalance를 CloudWatch로 감시한다 (t2/t3/t4g 계열로 바꿔서 쓸
  때만 알람이 생성됨 - m7i-flex는 크레딧 방식이 아니라 애초에 이 문제가
  없다).
- CPU/네트워크/접속자 수를 CloudWatch 대시보드(`palworld-server`) 하나로
  모아서 본다. 접속자 수는 5분마다 같은 Lambda가 REST API로 확인해서
  커스텀 지표로 기록.
- 세이브 데이터 EBS 볼륨은 매일 새벽 자동 스냅샷(최근 7개 보관)까지
  찍어둔다. 인스턴스가 죽어도 볼륨은 살아있지만, 볼륨 자체가 손상되는
  경우까지 대비.
- 팰월드 클라이언트는 Steam에서 자동 업데이트되지만 서버는 아니라서,
  6시간마다 접속자 없는 틈을 봐서 SteamCMD로 서버도 자동 업데이트한다.
  버전 바뀌면 SNS로 알림도 보냄.

아키텍처 자세한 내용이랑 왜 이렇게 짰는지는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)에 정리해뒀다.

## 대략 얼마 나오나

AZ(가용영역)마다 스팟 가격이 꽤 다르길래(같은 서울 리전이라 지연시간 차이는
없음) 비용 예측이 쉽게 `ap-northeast-2d`로 고정해뒀다(`availability_zone`
변수). 이 AZ 기준으로 대충 이 정도 나온다 (2026-07 조회 기준, 환율 1,400원 가정):

| 항목 | 월 예상 비용 |
|---|---|
| EC2 m7i-flex.large 스팟 (24시간) | ~$29 (약 40,600원) |
| EBS gp3 40GB (루트 20 + 데이터 20) | ~$3.7 (약 5,100원) |
| 예비 인스턴스 루트 볼륨 (정지 상태, 20GB) | ~$1.8 (약 2,500원) |
| Elastic IP (2024년부터 붙어있어도 시간당 과금됨) | ~$3.7 (약 5,100원) |
| SSM 파라미터 등 | ~$0.05 (약 70원) |
| **합계** | **약 $38.3 / 53,600원** |

> 원래 `t3.large` 기준으로 계산했을 땐 월 28,000원이었는데, 실제 배포
> 시점에 이 계정이 Free Plan이라 `t3.large`가 막혀서 사양이 같은
> `m7i-flex.large`로 바꿔 배포했다. 이 타입의 스팟 가격이 더 비싸서
> (2d 기준 시간당 $0.017 -> $0.04) 목표했던 4만원을 조금 넘는다.
> 다만 이 계정에 $114.74 무료 크레딧이 남아있어서(2026-10-03 만료)
> 그동안은 실제 청구 없이 돌아간다.

스팟 가격은 실시간으로 바뀌니 이건 어디까지나 참고용이고, 정확한 값은
`aws ec2 describe-spot-price-history --region ap-northeast-2 --instance-types
t3.large --product-descriptions "Linux/UNIX"` 로 직접 확인하는 게 제일 정확하다.

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
- Lambda가 인스턴스를 대체 기동한 뒤에는 Terraform state가 예전 인스턴스를
  계속 물고 있게 된다. 실제 서버는 정상 동작하지만 `terraform plan`에는
  diff가 보일 수 있고, Terraform으로 다시 관리하고 싶으면
  `terraform apply -replace="aws_instance.palworld"`로 정리하면 된다 -
  자세한 건 [ARCHITECTURE.md](docs/ARCHITECTURE.md#한계--운영-노트) 참고.
- 접속자 수 확인이 애매하게 실패하면(REST API 무응답 등) 그냥 "사람 있다"고
  치고 넘어간다. 괜히 전환했다가 낭비되는 비용보다 끊기는 게 더 나쁘다고
  판단해서 - 스팟->온디맨드, 온디맨드->스팟 양방향 다 마찬가지.
- 스팟 복귀 체크가 기본 30분 간격이라, 용량이 재확보돼도 최대 30분 정도는
  온디맨드 요금을 더 낼 수 있다.
