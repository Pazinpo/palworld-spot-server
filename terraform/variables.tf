variable "aws_region" {
  description = "배포 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 태그/이름에 사용할 프로젝트 식별자"
  type        = string
  default     = "palworld"
}

variable "availability_zone" {
  description = "배포할 가용영역. 같은 리전 안에서는 지연시간 차이가 사실상 없지만 스팟 가격은 AZ마다 꽤 다르므로, 비용 예측을 위해 고정해서 쓴다 (기본값은 조회 시점 기준 가장 저렴했던 2d)"
  type        = string
  default     = "ap-northeast-2d"
}

variable "instance_type" {
  description = "팰월드 서버 인스턴스 타입. 계정이 Free Plan(free-tier eligible 타입만 허용)이라면 t3.large 대신 m7i-flex.large(동일하게 2vCPU/8GB, spot 지원, free-tier eligible) 같은 걸 써야 한다. `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true` 로 계정에서 허용되는 타입을 확인할 수 있다."
  type        = string
  default     = "m7i-flex.large"
}

variable "spot_max_price" {
  description = "스팟 최대 입찰가 (비워두면 온디맨드 가격을 상한으로 사용)"
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "루트 볼륨 크기 (GB)"
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "세이브 데이터용 EBS 볼륨 크기 (GB)"
  type        = number
  default     = 20
}

variable "data_volume_device_name" {
  description = "세이브 데이터 EBS 볼륨을 붙일 디바이스 이름"
  type        = string
  default     = "/dev/sdf"
}

variable "allowed_cidr_blocks" {
  description = "팰월드 게임 포트 접속을 허용할 CIDR 목록 (친구들이 여러 곳에서 접속하므로 기본은 전체 허용)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "key_name" {
  description = "(선택) SSH 접속용 EC2 키 페어 이름. SSM Session Manager를 기본 접속 수단으로 쓰므로 비워둬도 됨"
  type        = string
  default     = null
}

variable "server_name" {
  description = "팰월드 서버 이름 (서버 목록에 표시)"
  type        = string
  default     = "My Palworld Spot Server"
}

variable "server_description" {
  description = "팰월드 서버 설명"
  type        = string
  default     = "Friends-only Palworld server on AWS Spot"
}

variable "server_password" {
  description = "(선택) 서버 접속 비밀번호. 비워두면 비밀번호 없이 접속 가능"
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_password" {
  description = "팰월드 관리자(RCON/REST API) 비밀번호. 반드시 지정해야 함"
  type        = string
  sensitive   = true
}

variable "max_players" {
  description = "최대 동시 접속 인원"
  type        = number
  default     = 4
}

variable "cpu_credit_balance_alarm_threshold" {
  description = "CPUCreditBalance 알람 임계값 (이 값 이하로 떨어지면 알람)"
  type        = number
  default     = 50
}

variable "alarm_notification_email" {
  description = "(선택) CloudWatch 알람을 받을 이메일 주소. 비워두면 SNS 구독을 생성하지 않음"
  type        = string
  default     = ""
}

variable "lambda_timeout" {
  description = "스팟 중단 대응 Lambda의 타임아웃(초)"
  type        = number
  default     = 100
}

variable "spot_reclaim_check_interval_minutes" {
  description = "온디맨드로 대체 기동된 상태일 때, 스팟으로 되돌릴 수 있는지 주기적으로 확인하는 간격(분)"
  type        = number
  default     = 30
}

variable "metrics_check_interval_minutes" {
  description = "접속자 수를 확인해서 CloudWatch 커스텀 지표(PlayerCount)로 기록하는 간격(분)"
  type        = number
  default     = 5
}

variable "snapshot_retention_count" {
  description = "세이브 데이터 EBS 볼륨의 일일 자동 스냅샷을 몇 개까지 보관할지"
  type        = number
  default     = 7
}
