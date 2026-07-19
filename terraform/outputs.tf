output "server_public_ip" {
  description = "친구들에게 공유할 서버 접속 IP (Elastic IP, 인스턴스가 바뀌어도 고정)"
  value       = aws_eip.palworld.public_ip
}

output "instance_id" {
  description = "현재 Terraform이 관리하는 EC2 인스턴스 ID"
  value       = aws_instance.palworld.id
}

output "data_volume_id" {
  description = "세이브 데이터 EBS 볼륨 ID"
  value       = aws_ebs_volume.palworld_data.id
}

output "lambda_function_name" {
  description = "스팟 중단 대응 Lambda 함수 이름"
  value       = aws_lambda_function.spot_interruption_handler.function_name
}

output "ssm_session_command" {
  description = "SSH 대신 SSM Session Manager로 인스턴스에 접속하는 명령"
  value       = "aws ssm start-session --target ${aws_instance.palworld.id} --region ${var.aws_region}"
}
