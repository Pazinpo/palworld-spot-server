# 아키텍처

친구 3~4명이 상시 접속하는 팰월드(Palworld) 전용 서버를, 스팟 인스턴스로
비용을 절감하면서도 실제 플레이 중 끊김은 최소화하는 것을 목표로 한다.

## 전체 구성

```
                        ┌─────────────────────────┐
                        │   Elastic IP (고정 IP)    │
                        └────────────┬─────────────┘
                                     │
                        ┌────────────▼─────────────┐
                        │   EC2 (t3.large, Spot)    │◄── 세이브 데이터 EBS 볼륨
                        │   Palworld Dedicated Srv  │    (루트 볼륨과 분리)
                        └────────────┬─────────────┘
                                     │ Spot Interruption Warning (2분 전)
                        ┌────────────▼─────────────┐
                        │   EventBridge Rule        │
                        └────────────┬─────────────┘
                                     │
                        ┌────────────▼─────────────┐
                        │   Lambda                  │
                        │   1) SSM으로 접속자 수 확인 │
                        │   2) 0명 -> 방치            │
                        │   3) 있으면 -> 온디맨드 대체 │
                        └───────────────────────────┘
```

## 1. 컴퓨팅 - 스팟 인스턴스 + persistent/stop

`aws_instance.palworld` (terraform/ec2.tf) 는 `instance_market_options` 로
**persistent 스팟 요청 + interruption_behavior=stop** 을 사용한다.

일반적인 "one-time" 스팟 요청은 중단되면 인스턴스가 **종료(terminate)**되고
끝이지만, persistent + stop 조합은 AWS가 스팟 용량을 회수할 때 인스턴스를
**정지(stop)**시켰다가, 나중에 스팟 용량이 다시 확보되면 **같은 인스턴스를
자동으로 재기동**해준다. 이 동작 하나로 아래 요구사항이 별도 코드 없이
자연스럽게 해결된다.

- "접속자가 0명이면 그냥 종료되게 두고, 나중에 스팟 용량 재확보되면 자동 재기동"
- 정지된 인스턴스는 루트/데이터 EBS 볼륨이 그대로 붙어있고, Elastic IP도
  연결이 풀리지 않으므로 재기동 시 세이브 데이터와 접속 IP가 모두 유지된다.

## 2. 네트워크 - 보안그룹

`terraform/security_group.tf` 는 인바운드로 아래 두 포트만 허용한다.

| 포트 | 프로토콜 | 용도 |
|---|---|---|
| 8211 | UDP | 팰월드 게임 포트 |
| 27015 | UDP | 쿼리 포트 (서버 상태/핑 조회) |

SSH(22번 포트)는 열지 않는다. 관리 접속은 EC2 인스턴스 역할에 붙인
`AmazonSSMManagedInstanceCore` 정책을 통해 **SSM Session Manager**로 한다
(`terraform output ssm_session_command` 참고). 인바운드 포트를 최소화하면서도
콘솔/CLI로 셸 접속이 가능하다.

## 3. 세이브 데이터 - 별도 EBS 볼륨

`terraform/ebs.tf` 의 `aws_ebs_volume.palworld_data` 는 루트 볼륨과 완전히
분리된 EBS 볼륨이다. 인스턴스가 교체(스팟 → 온디맨드, 또는 그 반대)되어도
이 볼륨만 재부착하면 팰월드 게임 설치본과 세이브가 그대로 유지된다.

- `lifecycle.prevent_destroy = true` 로 실수로 `terraform destroy`를 돌려도
  세이브 볼륨은 남도록 보호했다.
- `scripts/install-palworld.sh` 는 게임 설치 경로 자체(`/mnt/palworld-data/Palworld`)를
  이 볼륨 위에 둔다. 그래서 온디맨드로 대체 기동해도 SteamCMD로 게임을
  다시 받을 필요 없이 바로 이어서 뜬다.
- 볼륨 attach는 인스턴스 자신(초기 스팟 인스턴스는 User Data 스크립트,
  대체 온디맨드 인스턴스는 Lambda)이 수행하며, 두 경로 모두 같은
  `attach-volume` 호출을 하므로 "이미 붙어있음" 에러는 무시하고 넘어가도록
  멱등하게 작성했다.

## 4. 스팟 중단 대응 - EventBridge + Lambda

`terraform/eventbridge.tf` 는 계정 전체의 `EC2 Spot Instance Interruption
Warning` 이벤트(중단 2분 전 예고)를 구독해서 `lambda/spot_interruption_handler.py`
를 트리거한다. 인스턴스 ID로 필터링하지 않은 이유는, 대체 기동이 일어날
때마다 인스턴스 ID가 바뀌기 때문이다. 대신 Lambda 내부에서 `Project` 태그로
우리 서버가 맞는지 확인한다.

Lambda의 판단 로직:

1. **접속자 수 확인** - SSM Run Command로 인스턴스 내부에서 팰월드
   REST API(`http://127.0.0.1:8212/v1/api/players`)를 로컬 호출해 접속자
   수를 센다. REST API 응답이 실패하거나 시간 안에 결과를 못 받으면
   **"접속자가 있다"고 안전하게 간주**한다 (불필요한 온디맨드 전환 비용보다
   접속 끊김/세이브 유실이 훨씬 나쁜 결과이기 때문).
2. **0명이면** - 아무것도 하지 않는다. persistent+stop 스팟 요청이 알아서
   인스턴스를 정지시키고, 나중에 자동 재기동한다.
3. **접속자가 있으면** - 다음 순서로 즉시 대체 기동한다.
   1. 기존 스팟 요청을 취소한다 (취소하지 않으면 온디맨드가 뜬 상태에서
      AWS가 나중에 스팟 요청을 다시 채워서 서버가 중복 기동될 수 있다).
   2. 같은 AMI/보안그룹/서브넷/IAM 역할로 **온디맨드 인스턴스**를 새로
      기동한다 (User Data는 SSM Parameter Store에 저장해둔 것을 그대로 사용).
   3. 세이브 데이터 EBS 볼륨을 기존 인스턴스에서 분리해 새 인스턴스에 붙인다.
   4. Elastic IP를 새 인스턴스로 재연결한다 - 친구들은 같은 IP로 재접속만
      하면 된다.
   5. 기존 스팟 인스턴스를 명시적으로 종료한다.

### 한계 / 운영 노트

- **2분이라는 시간 제약**: 스팟 중단 예고는 AWS 사양상 항상 2분 전에
  온다. Lambda가 접속자 확인 + 온디맨드 기동 + 볼륨/EIP 이전을 그 안에
  끝내야 하므로 다소 빠듯하다 (`variables.tf`의 `lambda_timeout` 기본값
  110초). 네트워크/AWS API 지연이 겹치면 짧은 접속 끊김이 발생할 수 있다.
- **Terraform state 드리프트**: Lambda가 온디맨드로 대체 기동하면
  `aws_instance.palworld`, `aws_eip_association.palworld`,
  `aws_cloudwatch_metric_alarm.cpu_credit_balance` 는 여전히 "죽은 옛
  인스턴스"를 가리키게 된다. 상황이 안정된 뒤에는
  `terraform apply -replace="aws_instance.palworld"` 로 재조정하거나,
  실제로 살아있는 온디맨드 인스턴스를 그대로 쓰다가 나중에 수동으로
  스팟으로 되돌리는 식으로 운영한다. 이 프로젝트는 "장애조치(failover)"에
  최적화되어 있고, 그 이후의 재조정은 자동화하지 않았다.
- **CPUCreditBalance 알람**도 위와 같은 이유로 초기 인스턴스 ID를
  대상으로 생성된다. 대체 기동 이후에는 알람을 다시 만들어줘야 한다.
- **스팟 자동 복귀는 하지 않음**: 온디맨드로 넘어간 뒤 비용 절감을 위해
  다시 스팟으로 자동 전환하는 로직은 없다. 필요하면 수동으로
  전환하거나, 추후 별도 스케줄 Lambda로 확장할 수 있다.

## 5. 모니터링 - CPUCreditBalance 알람

`terraform/cloudwatch.tf`. t3 계열은 버스터블(CPU 크레딧 기반) 인스턴스라
팰월드처럼 CPU를 지속적으로 쓰는 게임 서버는 크레딧이 바닥나면
스로틀링되어 렉의 원인이 된다. `CPUCreditBalance` 지표가 임계값
(기본 50, `cpu_credit_balance_alarm_threshold` 변수) 아래로 5분 x 2회
연속 떨어지면 알람이 울리고, `alarm_notification_email` 변수를 채우면
이메일(SNS)로 알림을 받는다.

## 6. 설치 자동화 - User Data

`scripts/install-palworld.sh` 가 EC2 User Data로 실행되며 다음을 한다.

1. SteamCMD 실행에 필요한 32bit 멀티립 패키지 설치 (Ubuntu 22.04 기준)
2. 세이브 데이터 EBS 볼륨 attach + mount (NVMe 디바이스 매핑 처리 포함)
3. SteamCMD로 팰월드 전용 서버(App ID `2394010`) 설치
4. `PalWorldSettings.ini` 최초 1회 생성 (서버 이름/설명/비밀번호/최대 인원 등)
5. `systemd` 서비스(`palworld.service`) 등록 및 기동 - 크래시 시 자동 재시작

## 왜 Amazon Linux가 아니라 Ubuntu인가

SteamCMD는 32bit 바이너리를 필요로 하는데, Amazon Linux 2023은 32bit
멀티립 저장소를 제공하지 않는다. Ubuntu 22.04는 `dpkg --add-architecture
i386` 로 공식 지원하므로 팰월드/SteamCMD 계열 서버 배포에는 Ubuntu가
사실상 표준이다. AMI는 Canonical이 공식 관리하는 SSM 파라미터
(`/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id`)
로 항상 최신 버전을 가져온다.
