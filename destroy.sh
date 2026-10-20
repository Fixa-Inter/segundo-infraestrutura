#!/usr/bin/env bash
set -euo pipefail

export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

command -v aws >/dev/null || {
  echo "AWS CLI ausente"
  exit 1
}

command -v python3 >/dev/null || {
  echo "Python 3 ausente"
  exit 1
}

python3 - "$@" <<'PY'
import argparse
import json
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--execute", action="store_true")
parser.add_argument(
    "--delete-data",
    action="store_true",
    help="Inclui imagens ECR, logs, parametros SSM e bucket Firebase",
)
args = parser.parse_args()

REGION = "us-east-1"
CLUSTER = "cluster-fixa"
APIS = ("mobile", "web", "nosql", "ia")

FAMILIES = {f"fixa-{api}-api" for api in APIS}
NAMES = {"fixa-alb"} | FAMILIES | {
    f"fixa-{api}" for api in APIS
}


def aws(service, operation, *arguments, missing=()):
    result = subprocess.run(
        [
            "aws", service, operation,
            *arguments,
            "--region", REGION,
            "--output", "json",
            "--no-cli-pager",
        ],
        text=True,
        capture_output=True,
    )

    if result.returncode:
        match = re.search(r"\(([^)]+)\)", result.stderr)
        code = match[1] if match else "erro AWS/rede"

        if code in missing:
            return None

        raise RuntimeError(
            f"{service} {operation}: {code}"
        )

    return json.loads(result.stdout or "{}")


def values(service, operation, key, *arguments):
    return aws(
        service, operation, *arguments
    ).get(key, [])


def batches(items, size):
    for index in range(0, len(items), size):
        yield items[index:index + size]


def discover(account):
    plan = {
        name: []
        for name in (
            "services",
            "tasks",
            "task_definitions",
            "load_balancers",
            "target_groups",
            "security_groups",
            "certificates",
            "repositories",
            "log_groups",
            "parameters",
            "s3_objects",
        )
    }

    plan["cluster"] = False

    clusters = aws(
        "ecs", "describe-clusters",
        "--clusters", CLUSTER,
    ).get("clusters", [])

    if clusters and clusters[0]["status"] != "INACTIVE":
        plan["cluster"] = True

        instances = values(
            "ecs", "list-container-instances",
            "containerInstanceArns",
            "--cluster", CLUSTER,
        )

        if instances:
            raise RuntimeError(
                "Cluster possui instancias EC2. "
                "Este roteiro cobre Fargate; revise antes de excluir."
            )

        services = values(
            "ecs", "list-services", "serviceArns",
            "--cluster", CLUSTER,
        )

        for chunk in batches(services, 10):
            response = aws(
                "ecs", "describe-services",
                "--cluster", CLUSTER,
                "--services", *chunk,
            )

            if response.get("failures"):
                raise RuntimeError(
                    "Falha ao identificar servicos ECS"
                )

            for service in response["services"]:
                name = service["serviceName"]

                pattern = (
                    r"fixa-(mobile|web|nosql|ia)"
                    r"-api-service(?:-[A-Za-z0-9]+)?"
                )

                if not re.fullmatch(pattern, name):
                    raise RuntimeError(
                        "Servico fora do padrao no cluster: " + name
                    )

                plan["services"].append(
                    service["serviceArn"]
                )

                network = service.get(
                    "networkConfiguration", {}
                ).get("awsvpcConfiguration", {})

                plan["security_groups"] += network.get(
                    "securityGroups", []
                )

        tasks = values(
            "ecs", "list-tasks", "taskArns",
            "--cluster", CLUSTER,
        )

        for chunk in batches(tasks, 100):
            response = aws(
                "ecs", "describe-tasks",
                "--cluster", CLUSTER,
                "--tasks", *chunk,
            )

            if response.get("failures"):
                raise RuntimeError(
                    "Falha ao identificar tasks ECS"
                )

            for task in response["tasks"]:
                family = (
                    task["taskDefinitionArn"]
                    .rsplit("/", 1)[1]
                    .rsplit(":", 1)[0]
                )

                if family not in FAMILIES:
                    raise RuntimeError(
                        "Task de outra aplicacao no cluster. "
                        "Revise antes de excluir."
                    )

                plan["tasks"].append(task["taskArn"])

    for status in ("ACTIVE", "INACTIVE"):
        definitions = values(
            "ecs", "list-task-definitions",
            "taskDefinitionArns",
            "--family-prefix", "fixa-",
            "--status", status,
        )

        for arn in definitions:
            family = arn.rsplit("/", 1)[1].rsplit(":", 1)[0]

            if family in FAMILIES:
                plan["task_definitions"].append(arn)

    load_balancers = values(
        "elbv2", "describe-load-balancers",
        "LoadBalancers",
    )

    for lb in load_balancers:
        if lb["LoadBalancerName"] == "fixa-alb":
            plan["load_balancers"].append(
                lb["LoadBalancerArn"]
            )
            plan["security_groups"] += lb.get(
                "SecurityGroups", []
            )

    target_groups = values(
        "elbv2", "describe-target-groups",
        "TargetGroups",
    )

    for group in target_groups:
        linked = set(group.get("LoadBalancerArns", []))

        selected = (
            group["TargetGroupName"] in NAMES
            or linked.intersection(plan["load_balancers"])
        )

        if selected:
            if linked - set(plan["load_balancers"]):
                raise RuntimeError(
                    "Target Group compartilhado com outro ALB. "
                    "Revise antes de excluir."
                )

            plan["target_groups"].append(
                group["TargetGroupArn"]
            )

    groups = values(
        "ec2", "describe-security-groups",
        "SecurityGroups",
    )

    candidates = set(plan["security_groups"])

    for group in groups:
        tags = {
            tag["Key"]: tag["Value"]
            for tag in group.get("Tags", [])
        }

        if (
            group["GroupName"] in NAMES
            or tags.get("Project") == "fixa"
        ):
            candidates.add(group["GroupId"])

    plan["security_groups"] = [
        group["GroupId"]
        for group in groups
        if group["GroupId"] in candidates
        and group["GroupName"] != "default"
    ]

    certificates = values(
        "acm", "list-certificates",
        "CertificateSummaryList",
    )

    allowed_domains = {
        "fixa.solutions",
        "*.fixa.solutions",
    }

    for certificate in certificates:
        if certificate["DomainName"] not in allowed_domains:
            continue

        arn = certificate["CertificateArn"]

        details = aws(
            "acm", "describe-certificate",
            "--certificate-arn", arn,
        )["Certificate"]

        if (
            set(details.get("SubjectAlternativeNames", []))
            - allowed_domains
        ):
            continue

        if (
            set(details.get("InUseBy", []))
            - set(plan["load_balancers"])
        ):
            continue

        plan["certificates"].append(arn)

    if args.delete_data:
        allowed_repositories = {
            f"fixa/{api}-api" for api in APIS
        }

        repositories = values(
            "ecr", "describe-repositories",
            "repositories",
        )

        plan["repositories"] = [
            repository["repositoryName"]
            for repository in repositories
            if repository["repositoryName"]
            in allowed_repositories
        ]

        allowed_logs = {
            f"/ecs/{name}" for name in NAMES
        }

        logs = values(
            "logs", "describe-log-groups",
            "logGroups",
            "--log-group-name-prefix", "/ecs/fixa",
        )

        plan["log_groups"] = [
            group["logGroupName"]
            for group in logs
            if group["logGroupName"] in allowed_logs
        ]

        prefixes = tuple(
            f"/fixa/{api}/" for api in APIS
        )

        parameters = values(
            "ssm", "describe-parameters",
            "Parameters",
            "--parameter-filters",
            "Key=Name,Option=BeginsWith,Values=/fixa/",
        )

        plan["parameters"] = [
            parameter["Name"]
            for parameter in parameters
            if parameter["Name"].startswith(prefixes)
        ]

        bucket = f"fixa-secrets-{account}-{REGION}"

        exists = aws(
            "s3api", "head-bucket",
            "--bucket", bucket,
            "--expected-bucket-owner", account,
            missing=("404", "NoSuchBucket", "NotFound"),
        )

        if exists is not None:
            plan["bucket"] = bucket

            content = aws(
                "s3api", "list-object-versions",
                "--bucket", bucket,
                "--expected-bucket-owner", account,
            )

            plan["s3_objects"] = [
                {
                    "Key": obj["Key"],
                    "VersionId": obj["VersionId"],
                }
                for category in ("Versions", "DeleteMarkers")
                for obj in content.get(category, [])
            ]

            for obj in plan["s3_objects"]:
                if not re.fullmatch(
                    r"firebase/[a-f0-9]{64}\.json|firebase\.json",
                    obj["Key"],
                ):
                    raise RuntimeError(
                        "Bucket Firebase possui arquivos "
                        "fora do padrao. Revise antes de excluir."
                    )

    # Normaliza o inventario para detectar mudancas antes da exclusao.
    for key, value in plan.items():
        if isinstance(value, list):
            normalized = sorted({
                json.dumps(item, sort_keys=True)
                for item in value
            })
            plan[key] = [
                json.loads(item) for item in normalized
            ]

    return plan


def execute(plan, account):
    # Primeiro encerra os servicos e tasks.
    for service in plan["services"]:
        aws(
            "ecs", "delete-service",
            "--cluster", CLUSTER,
            "--service", service,
            "--force",
        )

    for chunk in batches(plan["services"], 10):
        aws(
            "ecs", "wait", "services-inactive",
            "--cluster", CLUSTER,
            "--services", *chunk,
        )

    remaining_tasks = []

    if plan["cluster"]:
        remaining_tasks = values(
            "ecs", "list-tasks", "taskArns",
            "--cluster", CLUSTER,
        )

    for task in remaining_tasks:
        if task not in plan["tasks"]:
            raise RuntimeError(
                "Nova task apareceu. Reexecute o inventario."
            )

        aws(
            "ecs", "stop-task",
            "--cluster", CLUSTER,
            "--task", task,
            "--reason", "Limpeza FIXA confirmada",
        )

    for chunk in batches(plan["tasks"], 100):
        aws(
            "ecs", "wait", "tasks-stopped",
            "--cluster", CLUSTER,
            "--tasks", *chunk,
        )

    if plan["cluster"]:
        aws(
            "ecs", "delete-cluster",
            "--cluster", CLUSTER,
        )

    # Depois remove ALB e Target Groups.
    for lb in plan["load_balancers"]:
        aws(
            "elbv2", "modify-load-balancer-attributes",
            "--load-balancer-arn", lb,
            "--attributes",
            "Key=deletion_protection.enabled,Value=false",
        )

        aws(
            "elbv2", "delete-load-balancer",
            "--load-balancer-arn", lb,
        )

    if plan["load_balancers"]:
        aws(
            "elbv2", "wait", "load-balancers-deleted",
            "--load-balancer-arns",
            *plan["load_balancers"],
        )

    for group in plan["target_groups"]:
        aws(
            "elbv2", "delete-target-group",
            "--target-group-arn", group,
        )

    for arn in plan["task_definitions"]:
        aws(
            "ecs", "deregister-task-definition",
            "--task-definition", arn,
        )

    for chunk in batches(plan["task_definitions"], 10):
        response = aws(
            "ecs", "delete-task-definitions",
            "--task-definitions", *chunk,
        )

        if response.get("failures"):
            raise RuntimeError(
                "Algumas task definitions nao puderam ser excluidas"
            )

    for arn in plan["certificates"]:
        certificate = aws(
            "acm", "describe-certificate",
            "--certificate-arn", arn,
        )["Certificate"]

        if certificate.get("InUseBy"):
            raise RuntimeError(
                "Certificado ainda associado a um recurso. "
                "Aguarde e execute novamente."
            )

        aws(
            "acm", "delete-certificate",
            "--certificate-arn", arn,
        )

    # Dados sao incluidos somente com --delete-data.
    for repository in plan["repositories"]:
        aws(
            "ecr", "delete-repository",
            "--repository-name", repository,
            "--force",
        )

    for name in plan["log_groups"]:
        aws(
            "logs", "delete-log-group",
            "--log-group-name", name,
        )

    for chunk in batches(plan["parameters"], 10):
        response = aws(
            "ssm", "delete-parameters",
            "--names", *chunk,
        )

        if response.get("InvalidParameters"):
            raise RuntimeError(
                "Falha na exclusao de parametros SSM"
            )

    if plan.get("bucket"):
        for chunk in batches(plan["s3_objects"], 1000):
            response = aws(
                "s3api", "delete-objects",
                "--bucket", plan["bucket"],
                "--expected-bucket-owner", account,
                "--delete",
                json.dumps({
                    "Objects": chunk,
                    "Quiet": True,
                }),
            )

            if response.get("Errors"):
                raise RuntimeError(
                    "Falha na exclusao dos objetos S3"
                )

        aws(
            "s3api", "delete-bucket",
            "--bucket", plan["bucket"],
            "--expected-bucket-owner", account,
        )

    # Aguarda liberacao das interfaces e referencias internas.
    pending = plan["security_groups"][:]

    for attempt in range(30):
        for group in pending[:]:
            try:
                aws(
                    "ec2", "delete-security-group",
                    "--group-id", group,
                    missing=("InvalidGroup.NotFound",),
                )
                pending.remove(group)

            except RuntimeError as error:
                if "DependencyViolation" not in str(error):
                    raise

        if not pending:
            break

        time.sleep(10)

    if pending:
        raise RuntimeError(
            "Security Groups ainda possuem dependencias: "
            + ", ".join(pending)
        )


try:
    account = aws(
        "sts", "get-caller-identity"
    )["Account"]

    plan = discover(account)

    print("CONTA:", account)
    print("REGIAO:", REGION)
    print(json.dumps(plan, indent=2))

    if not args.delete_data:
        print(
            "ECR, logs, SSM e bucket Firebase preservados. "
            "Use --delete-data para inclui-los."
        )

    if not args.execute:
        print("SIMULACAO: nenhuma exclusao executada.")
        print("Adicione --execute para continuar.")
        sys.exit(0)

    expected = f"APAGAR-FIXA-{account}"

    # A confirmacao usa o terminal porque stdin contem este script.
    with open("/dev/tty", "r+") as terminal:
        terminal.write(
            f"Digite {expected} para confirmar: "
        )
        terminal.flush()
        confirmation = terminal.readline().strip()

    if confirmation != expected:
        sys.exit("Cancelado")

    if aws("sts", "get-caller-identity")["Account"] != account:
        raise RuntimeError(
            "Conta mudou. Operacao cancelada."
        )

    if discover(account) != plan:
        raise RuntimeError(
            "Inventario mudou. Revise e execute novamente."
        )

    execute(plan, account)

    print("Exclusoes solicitadas concluidas.")
    print(
        "Task definitions podem permanecer "
        "DELETE_IN_PROGRESS temporariamente."
    )

except (
    RuntimeError,
    KeyError,
    ValueError,
    EOFError,
    OSError,
) as error:
    print("ERRO:", error, file=sys.stderr)
    sys.exit(1)
PY