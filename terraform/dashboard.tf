# CPU/네트워크(EC2 기본 지표) + 접속자 수(커스텀 지표)를 한 화면에서 본다.
#
# CPU/네트워크 위젯은 특정 인스턴스 ID를 지정하지 않고 SEARCH 표현식으로
# "AWS/EC2 네임스페이스의 해당 지표 전체"를 찾도록 했다. 스팟<->온디맨드
# 전환으로 인스턴스 ID가 바뀌어도 대시보드를 수동으로 고칠 필요가 없다
# (계정에 다른 EC2 인스턴스가 없다는 전제 - 개인 프로젝트라 문제 없음).
resource "aws_cloudwatch_dashboard" "palworld" {
  dashboard_name = "${var.project_name}-server"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CPU Utilization (%)"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          metrics = [
            [{ expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 300)", id = "cpu" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Network In/Out (bytes)"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          metrics = [
            [{ expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"NetworkIn\"', 'Sum', 300)", id = "netin" }],
            [{ expression = "SEARCH('{AWS/EC2,InstanceId} MetricName=\"NetworkOut\"', 'Sum', 300)", id = "netout" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Player Count"
          view   = "timeSeries"
          region = var.aws_region
          period = var.metrics_check_interval_minutes * 60
          stat   = "Maximum"
          metrics = [
            ["${var.project_name}/GameServer", "PlayerCount"]
          ]
        }
      }
    ]
  })
}
