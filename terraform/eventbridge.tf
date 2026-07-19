# 스팟 인스턴스 중단 2분 전 예고(EC2 Spot Instance Interruption Warning)를 감지한다.
# 특정 인스턴스 ID로 필터링하지 않는 이유: 인스턴스가 교체(replace)될 때마다
# ID가 바뀌므로, 계정 전체 이벤트를 받아 Lambda 안에서 Project 태그로 걸러낸다.
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.project_name}-spot-interruption"
  description = "Palworld 스팟 인스턴스 중단 2분 전 예고"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption_lambda" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "spot-interruption-handler"
  arn       = aws_lambda_function.spot_interruption_handler.arn
}
