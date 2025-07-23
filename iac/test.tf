output "instance_ip" {
  value = aws_instance.example.public_ip
}

output "instance_ip2" {
  value = aws_instance.example2.public_ip
}
