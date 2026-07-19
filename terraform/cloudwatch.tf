# t2/t3/t4g 같은 버스터블(CPU 크레딧 기반) 인스턴스는, 팰월드처럼 CPU를 계속
# 쓰는 게임 서버를 돌리면 크레딧이 바닥나서 스로틀링(렉)이 발생할 수 있다.
# 이를 사전에 감지하기 위한 알람인데, m7i-flex/c7i-flex 같은 비-버스터블
# 타입은 CPUCreditBalance 지표 자체가 없으므로 그런 경우엔 알람을 만들지 않는다.
#
# 주의: 이 알람은 Terraform이 초기 생성한 인스턴스 ID를 대상으로 한다.
# Lambda가 온디맨드로 대체 기동한 뒤에는 새 인스턴스 ID로 알람을 다시
# 만들어줘야 한다 (docs/ARCHITECTURE.md의 운영 노트 참고).
locals {
  instance_is_burstable = can(regex("^t[234]g?\\.", var.instance_type))
}

resource "aws_sns_topic" "alerts" {
  count = var.alarm_notification_email != "" ? 1 : 0
  name  = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alarm_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

resource "aws_cloudwatch_metric_alarm" "cpu_credit_balance" {
  count = local.instance_is_burstable ? 1 : 0

  alarm_name          = "${var.project_name}-cpu-credit-balance-low"
  alarm_description   = "CPUCreditBalance가 낮아지면 팰월드 서버 성능 저하(렉)가 발생할 수 있음"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = var.cpu_credit_balance_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.palworld.id
  }

  alarm_actions = var.alarm_notification_email != "" ? [aws_sns_topic.alerts[0].arn] : []
  ok_actions    = var.alarm_notification_email != "" ? [aws_sns_topic.alerts[0].arn] : []
}
