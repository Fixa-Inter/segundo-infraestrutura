<div align="center">

# FIXA · Infraestrutura AWS

Infraestrutura como código para publicação segura e reproduzível dos serviços do FIXA.

![badge](https://img.shields.io/badge/Terraform-1.10.5-844FBA?logo=terraform&logoColor=white) ![badge](https://img.shields.io/badge/AWS-ECS-FF9900?logo=amazonwebservices&logoColor=white) ![badge](https://img.shields.io/badge/Docker-Containers-2496ED?logo=docker&logoColor=white) ![badge](https://img.shields.io/badge/License-MIT-green)

</div>

---

## ✨ Visão geral

O projeto administra os recursos necessários para executar as APIs Mobile, Web, NoSQL e IA em `us-east-1`. PostgreSQL, Redis, MongoDB, Qdrant, Firebase e DNS permanecem externos.

## 🚀 Funcionalidades

- Provisionamento da infraestrutura com Terraform
- Publicação das quatro APIs no ECS Fargate
- Armazenamento das imagens no Amazon ECR
- Distribuição de tráfego com Application Load Balancer
- Certificados HTTPS gerenciados pelo ACM
- Configurações protegidas no SSM
- Preparação das credenciais Firebase
- Validação e verificação de saúde dos serviços
- Integração opcional com o DNS da Hostinger
- Retomada de implantações e destruição controlada

## 🧰 Tecnologias

| Área | Tecnologias |
| --- | --- |
| **Infraestrutura** | Terraform e AWS Provider |
| **Computação** | ECS Fargate |
| **Rede e segurança** | ALB, ACM e SSM |
| **Imagens** | Docker e Amazon ECR |
| **Automação** | Python e Shell Script |

## 📄 Licença

Este projeto é distribuído sob a licença MIT. Consulte o arquivo [LICENSE](LICENSE).

---

<div align="center">
  Desenvolvido pela <strong>Fixa-Inter</strong>.
</div>
