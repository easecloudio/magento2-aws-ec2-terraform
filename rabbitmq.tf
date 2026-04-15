


/////////////////////////////////////////////////////[ AMAZON MQ BROKER ]/////////////////////////////////////////////////

# # ---------------------------------------------------------------------------------------------------------------------#
# Create RabbitMQ - queue message broker
# # ---------------------------------------------------------------------------------------------------------------------#
resource "aws_mq_broker" "this" {
  broker_name        = "${local.project}-rabbitmq"
  engine_type        = "RabbitMQ"
  engine_version     = local.env.rabbitmq.engine_version
  host_instance_type = local.env.rabbitmq.host_instance_type
  security_groups    = [aws_security_group.rabbitmq.id]
  subnet_ids         = [values(aws_subnet.this).0.id]
  user {
    username = local.env.brand
    password = random_password.this["rabbitmq"].result
  }
  tags = {
    Name = "${local.project}-rabbitmq"
  }
}


