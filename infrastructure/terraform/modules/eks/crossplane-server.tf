# Instance identity can only manage SSM sessions/agent communication, not AWS resources.
resource "aws_iam_role" "crossplane_server" {
  name = "${var.name_prefix}-crossplane-server"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "crossplane_server_ssm" {
  role       = aws_iam_role.crossplane_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "crossplane_server" {
  name = "${var.name_prefix}-crossplane-server"
  role = aws_iam_role.crossplane_server.name
}
# The approved regional image is frozen in a reviewed saved Terraform plan;
# claims receive that one image ID and cannot choose arbitrary public AMIs.
data "aws_ssm_parameter" "approved_server_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
output "approved_server_ami_id" { value = nonsensitive(data.aws_ssm_parameter.approved_server_ami.value) }
output "ec2_instance_profile_name" { value = aws_iam_instance_profile.crossplane_server.name }
