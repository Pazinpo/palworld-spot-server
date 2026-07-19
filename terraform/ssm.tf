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
