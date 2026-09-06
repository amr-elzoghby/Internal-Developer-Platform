# Vendored unchanged from the official v3.5.0 controller release IAM policy.
data "aws_iam_policy_document" "load_balancer_controller_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.name_prefix}-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_trust.json
}
resource "aws_iam_policy" "load_balancer_controller" {
  name   = "${var.name_prefix}-load-balancer-controller"
  policy = file("${path.module}/load-balancer-controller-policy.json")
}
resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}
output "load_balancer_controller_role_arn" { value = aws_iam_role.load_balancer_controller.arn }
