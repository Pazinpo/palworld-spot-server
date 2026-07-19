data "archive_file" "spot_interruption_handler" {
  type        = "zip"
  source_file = "${path.module}/../lambda/spot_interruption_handler.py"
  output_path = "${path.module}/../lambda/spot_interruption_handler.zip"
}

resource "aws_cloudwatch_log_group" "spot_interruption_handler" {
  name              = "/aws/lambda/${var.project_name}-spot-interruption-handler"
  retention_in_days = 14
}

resource "aws_lambda_function" "spot_interruption_handler" {
  function_name = "${var.project_name}-spot-interruption-handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "spot_interruption_handler.handler"
  runtime       = "python3.12"
  timeout       = var.lambda_timeout
  memory_size   = 256

  filename         = data.archive_file.spot_interruption_handler.output_path
  source_code_hash = data.archive_file.spot_interruption_handler.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.spot_interruption_handler]

  environment {
    variables = {
      PROJECT_NAME             = var.project_name
      DATA_VOLUME_ID           = aws_ebs_volume.palworld_data.id
      DATA_VOLUME_DEVICE       = var.data_volume_device_name
      EIP_ALLOCATION_ID        = aws_eip.palworld.id
      SECURITY_GROUP_ID        = aws_security_group.palworld.id
      SUBNET_ID                = data.aws_subnet.selected.id
      AMI_ID                   = data.aws_ssm_parameter.ubuntu_ami.value
      INSTANCE_PROFILE_NAME    = aws_iam_instance_profile.palworld.name
      INSTANCE_TYPE            = var.instance_type
      USER_DATA_PARAMETER_NAME = aws_ssm_parameter.user_data.name
    }
  }
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.spot_interruption_handler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.spot_interruption.arn
}
