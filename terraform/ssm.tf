# 온디맨드 대체 기동 시 Lambda가 사용할 User Data를 저장해둔다.
# Lambda 환경변수는 총 4KB 제한이 있어 렌더링된 설치 스크립트 전체를
# 담기에 부족할 수 있으므로, SSM Parameter Store(Advanced tier, 최대 8KB)에
# 저장하고 Lambda는 파라미터 이름만 참조한다.
resource "aws_ssm_parameter" "user_data" {
  name  = "/${var.project_name}/user-data"
  type  = "String"
  tier  = "Advanced"
  value = local.user_data
}

# 예비(warm standby) 인스턴스용 경량 User Data. 세이브 볼륨을 건드리지
# 않고 패키지/SteamCMD 부트스트랩만 하므로 별도로 렌더링해서 저장한다.
resource "aws_ssm_parameter" "standby_user_data" {
  name  = "/${var.project_name}/standby-user-data"
  type  = "String"
  tier  = "Advanced"
  value = file("${path.module}/../scripts/warm-standby.sh")
}
