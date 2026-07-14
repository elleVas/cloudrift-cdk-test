# Guida: creare un utente IAM temporaneo per cloudrift-cdk-test

Questa guida spiega come creare un utente IAM con i permessi necessari per deployare lo stack CDK e lanciare cloudrift. L'utente va eliminato dopo il test.

---

## Prerequisiti

- Accesso alla console AWS con permessi di gestione IAM
- Un account sandbox/dev (mai produzione)

---

## Step 1 — Crea la policy

1. Vai su **IAM → Policies → Create policy**
2. Seleziona la tab **JSON**
3. Incolla:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudriftCDKTestFullAccess",
      "Effect": "Allow",
      "Action": [
        "cloudformation:*",
        "ec2:*",
        "rds:*",
        "elasticloadbalancing:*",
        "s3:*",
        "logs:*",
        "lambda:*",
        "dynamodb:*",
        "iam:*",
        "secretsmanager:*",
        "ssm:*",
        "ecr:*",
        "sts:GetCallerIdentity",
        "elasticfilesystem:DescribeFileSystems",
        "elasticache:DescribeCacheClusters",
        "cloudwatch:GetMetricStatistics",
        "pricing:GetProducts"
      ],
      "Resource": "*"
    }
  ]
}
```

4. Clicca **Next**
5. Nome: `CloudriftTestFullAccess`
6. Clicca **Create policy**

> **Nota**: `Resource: *` è necessario perché le API Describe/List di AWS e il CDK bootstrap richiedono accesso globale. La sicurezza è garantita dall'uso di un account sandbox dedicato.

---

## Step 2 — Crea l'utente

1. Vai su **IAM → Users → Create user**
2. Nome: `cloudrift-test` (o quello che preferisci)
3. **Non** spuntare "Provide user access to the AWS Management Console" (serve solo accesso programmatico)
4. Clicca **Next**
5. Seleziona **Attach policies directly**
6. Cerca `CloudriftTestFullAccess` e selezionala
7. Clicca **Next → Create user**

---

## Step 3 — Crea le Access Key

1. Vai su **IAM → Users → `cloudrift-test`**
2. Tab **Security credentials**
3. Sezione "Access keys" → **Create access key**
4. Seleziona **Command Line Interface (CLI)**
5. Conferma e clicca **Create access key**
6. **Copia subito** Access Key ID e Secret Access Key (la secret non sarà più visibile dopo)

---

## Step 4 — Configura il terminale

```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=wJalr...
export AWS_DEFAULT_REGION=us-east-1
```

Verifica:

```bash
aws sts get-caller-identity
# Deve restituire l'account ID senza errori
```

---

## Step 5 — Bootstrap CDK (una tantum)

```bash
npx cdk bootstrap
```

Se fallisce con errori di permessi e hai appena creato la policy, verifica di aver incluso `ssm:*` e `ecr:*` (servono al bootstrap).

Se il bootstrap era già fallito in precedenza:

```bash
aws cloudformation delete-stack --stack-name CDKToolkit
aws cloudformation wait stack-delete-complete --stack-name CDKToolkit
npx cdk bootstrap
```

---

## Step 6 — Deploy e test

```bash
npm run deploy
npm run post-deploy
# Aspetta 5 minuti
npm run validate:cli   # output a terminale
npm run validate:pdf   # output a terminale + PDF
npm run validate       # check automatico pass/fail
```

---

## Step 7 — Cleanup

```bash
# Distruggi tutte le risorse AWS
npm run cleanup
```

---

## Step 8 — Elimina l'utente

Dopo il test, dalla console AWS:

1. **IAM → Users → `cloudrift-test` → Delete**
2. **IAM → Policies → `CloudriftTestFullAccess` → Delete**

---

## Alternativa: AdministratorAccess

Se non vuoi creare una policy custom, puoi attaccare direttamente la managed policy `AdministratorAccess` all'utente:

1. IAM → Users → `cloudrift-test` → Permissions → Add permissions
2. Attach policies directly → cerca `AdministratorAccess` → seleziona

Funziona per tutto (bootstrap, deploy, cloudrift). Da rimuovere/eliminare appena finito il test.

---

## Alternativa: IAM Identity Center (SSO)

Se usi AWS Organizations con IAM Identity Center:

1. Crea un **Permission Set** con inline policy (stesso JSON sopra)
2. Assegnalo al tuo utente sull'account target
3. Dal portale SSO (`https://d-xxxxxxxx.awsapps.com/start`) prendi le credenziali temporanee
4. Oppure configura un profilo SSO:

```bash
aws configure sso
# ti chiede: SSO start URL, region, account, permission set
export AWS_PROFILE=il-nome-scelto
aws sso login --profile il-nome-scelto
```

> **Requisito**: l'account AWS deve essere presente nell'Organization e visibile in Identity Center. Se vedi "Non disponi di alcun account AWS", devi prima aggiungere un account all'Organization.

---

## Riepilogo comandi

| Comando | Cosa fa |
|---------|---------|
| `npm run deploy` | Deploya lo stack (~239 risorse) |
| `npm run post-deploy` | Ferma EC2 e RDS |
| `npm run validate` | Check automatico (pass/fail per ogni scanner) |
| `npm run validate:cli` | Cloudrift con output tabelle a terminale |
| `npm run validate:pdf` | Cloudrift con output tabelle + report PDF |
| `npm run cleanup` | Distrugge tutte le risorse AWS |
| `npm run test:full` | One-liner: deploy → stop → wait 5min → validate |
