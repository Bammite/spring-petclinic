# ==============================================================================
# 1. Conservé : EC2 Launch Template (Inchangé)
# ==============================================================================
resource "aws_launch_template" "app" {
  name_prefix   = "${local.name_prefix}-template-"
  image_id      = var.ec2_ami_id
  instance_type = var.ec2_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.main.arn
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh", {
    bucket_name       = aws_s3_bucket.deploy.id
    db_secret_id      = aws_secretsmanager_secret.db_secret.name
    db_proxy_endpoint = aws_db_instance.db.address
    db_name           = "petclinic"
    aws_region        = var.aws_region
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.name_prefix}-instance" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${local.name_prefix}-volume" })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

# ==============================================================================
# 2. NOUVEAU : Alarme CloudWatch pour le rollback automatique sur erreurs 5xx
# ==============================================================================
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1 # S'il y a 1 erreur ou plus
  alarm_description   = "Déclenché si l'application renvoie des erreurs 5xx durant le déploiement"

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

# ==============================================================================
# 3. MODIFIÉ : Auto Scaling Group (Conserve vos variables + ajoute le Zéro-Downtime)
# ==============================================================================
resource "aws_autoscaling_group" "app" {
  name_prefix               = "${local.name_prefix}-asg-"
  vpc_zone_identifier       = aws_subnet.private_app[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300 # Laisser le temps à Spring Boot de boot
  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  force_delete              = true

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # --- AJOUTS ICI POUR LES 2 DÉFIS ---
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100 # Défi 1 : Zéro coupure (garde 100% de la capacité)
      max_healthy_percentage = 200 # Défi 1 : Crée de nouvelles instances en parallèle
      instance_warmup        = 180 # Laisse 3 min à l'app pour répondre
      auto_rollback          = true # Défi 2 : Activer le rollback automatique
      
      alarm_specification {
        alarms = [aws_cloudwatch_metric_alarm.alb_5xx.alarm_name]
      }
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_s3_object.app_jar
  ]
}

# ==============================================================================
# 4. Conservé : Auto Scaling CPU Policy (Inchangé)
# ==============================================================================
resource "aws_autoscaling_policy" "cpu_scaling" {
  name                   = "${local.name_prefix}-cpu-scaling-policy"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}