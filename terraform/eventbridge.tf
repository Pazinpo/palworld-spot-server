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

# 온디맨드로 대체 기동된 상태라면, 주기적으로 접속자가 없는 틈을 봐서
# 스팟으로 자동 복귀를 시도한다 (같은 Lambda가 Scheduled Event로 판단해서 처리).
resource "aws_cloudwatch_event_rule" "spot_reclaim_schedule" {
  name                = "${var.project_name}-spot-reclaim-schedule"
  description         = "온디맨드 -> 스팟 자동 복귀 가능 여부를 주기적으로 확인"
  schedule_expression = "rate(${var.spot_reclaim_check_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "spot_reclaim_lambda" {
  rule      = aws_cloudwatch_event_rule.spot_reclaim_schedule.name
  target_id = "spot-reclaim-handler"
  arn       = aws_lambda_function.spot_interruption_handler.arn
  input     = jsonencode({ task = "reclaim_check" })
}

resource "aws_lambda_permission" "allow_eventbridge_schedule" {
  statement_id  = "AllowExecutionFromEventBridgeSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_interruption_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_reclaim_schedule.arn
}

# 접속자 수를 주기적으로 확인해서 CloudWatch 커스텀 지표로 기록한다
# (CloudWatch 대시보드에서 CPU/네트워크 지표와 같이 볼 수 있다).
resource "aws_cloudwatch_event_rule" "metrics_schedule" {
  name                = "${var.project_name}-metrics-schedule"
  description         = "접속자 수를 CloudWatch 커스텀 지표로 주기 기록"
  schedule_expression = "rate(${var.metrics_check_interval_minutes} minutes)"
}

resource "aws_cloudwatch_event_target" "metrics_lambda" {
  rule      = aws_cloudwatch_event_rule.metrics_schedule.name
  target_id = "metrics-handler"
  arn       = aws_lambda_function.spot_interruption_handler.arn
  input     = jsonencode({ task = "record_metrics" })
}

resource "aws_lambda_permission" "allow_eventbridge_metrics_schedule" {
  statement_id  = "AllowExecutionFromEventBridgeMetricsSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_interruption_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.metrics_schedule.arn
}
