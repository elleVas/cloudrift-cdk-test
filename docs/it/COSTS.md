# Costi — cloudrift-cdk-test

Stima dettagliata dei costi per le risorse deployate dallo stack.

> Prezzi riferiti a **us-east-1** (giugno 2026). Altre region possono variare del 5-15%.

---

## Per risorsa

| Risorsa | Tipo | Costo/ora | Costo/giorno | Costo/mese |
|---------|------|-----------|--------------|------------|
| EBS gp2 8GB (unattached) | Volume | — | $0.027 | $0.80 |
| EBS gp3 8GB (unattached) | Volume | — | $0.021 | $0.64 |
| EBS gp3 8GB (stopped EC2 root) | Volume | — | $0.021 | $0.64 |
| EBS gp2 10GB (idle EC2 root) | Volume | — | $0.033 | $1.00 |
| Elastic IP (unassociated) | Network | $0.005 | $0.12 | $3.60 |
| EC2 t3.micro (stopped) | Compute | $0.00 | $0.00 | $0.00 |
| EC2 t3.micro (running, idle) | Compute | $0.0104 | $0.25 | $7.59 |
| RDS db.t3.micro (stopped) | Database | $0.00 | $0.00 | $0.00 |
| RDS storage 20GB gp3 (stopped) | Storage | — | $0.053 | $1.60 |
| ALB (no targets) | Network | $0.0225 | $0.54 | $16.43 |
| Log Group (no retention) | Logs | $0.00 | $0.00 | $0.00* |
| S3 Bucket (empty, no lifecycle) | Storage | $0.00 | $0.00 | $0.00 |
| Lambda (never invoked) | Compute | $0.00 | $0.00 | $0.00 |
| DynamoDB (5 RCU + 5 WCU) | Database | — | $0.10 | $3.11 |
| ENI (orphaned) | Network | $0.00 | $0.00 | $0.00 |
| EBS Snapshot 1GB | Storage | — | $0.002 | $0.05 |
| EFS (quasi vuoto) | Storage | $0.00 | $0.00 | ~$0.00 |
| ElastiCache cache.t4g.micro | Database | $0.016 | $0.38 | $11.68 |
| Redshift dc2.large (1 nodo) | Database | $0.250 | $6.00 | $182.50 |
| OpenSearch t3.small.search + 10GB | Analytics | $0.037 | $0.89 | $27.08 |
| MSK 2× kafka.t3.small + storage | Streaming | $0.085 | $2.05 | $62.34 |
| FSx for Lustre 1200GiB SCRATCH_2 ⚠️ | Storage | ~$0.233 | ~$5.60 | ~$168 |
| DocumentDB db.t3.medium | Database | $0.077 | $1.85 | $56.21 |
| Neptune db.t3.medium | Database | $0.082 | $1.97 | $59.86 |
| Amazon MQ mq.t3.micro | Messaging | $0.017 | $0.41 | $12.41 |
| VPN Site-to-Site connection | Network | $0.050 | $1.20 | $36.50 |
| Transit Gateway + 1 attachment | Network | $0.050 | $1.20 | $36.50 |
| Kinesis 1 shard (provisioned) | Streaming | $0.015 | $0.36 | $10.95 |
| Secrets Manager (password gestita Redshift) | Secret | — | $0.013 | $0.40 |
| **NAT Gateway** (opzionale) | Network | $0.045 | $1.08 | $32.85 |
| **WorkSpaces + Simple AD** (opt-in) | Compute | ~$0.35 | ~$8.40 | ~$255 |

*Log Group: costa $0.03/GB ingested — con zero log scritti, costo zero.

⚠️ Il pricing throughput-capacity di FSx for Lustre è una stima best-effort, non verificata indipendentemente — controlla la prima bolletta prima di farci affidamento per la pianificazione (vedi `docs/it/ARCHITECTURE.md`, Limitazioni note).

---

## Totali

Queste sono cifre mensili-equivalenti (utili per confrontare le risorse tra loro), non quanto costa davvero un test — vedi "Quanto costa davvero un ciclo di test" più sotto.

| Scenario | Costo/giorno | Costo/settimana | Costo/mese |
|----------|-------------|-----------------|------------|
| **Solo stack base** (risorse pre-esistenti, senza NAT) | ~$1.20 | ~$8.40 | ~$36.16 |
| **Stack base + NAT Gateway** | ~$2.28 | ~$15.96 | ~$69.01 |
| **Stack completo** (base + tutti gli scanner verticali, senza WorkSpaces) | ~$22.30 | ~$156.10 | ~$677 |
| **Stack completo + WorkSpaces** | ~$30.70 | ~$214.90 | ~$932 |

---

## Quanto costa davvero un ciclo di test

I totali sopra assumono che una risorsa resti attiva un giorno/settimana/mese intero — ma il workflow previsto è `npm run test:full` (deploy → post-deploy → attesa 5min → validate → esegui tu `npm run cleanup`), un ciclo di circa 1-2 ore una volta considerato il tempo di provisioning di MSK/DocumentDB/Neptune/Redshift/OpenSearch. Alla tariffa oraria dello **stack completo** (~$0.93/ora combinati), un ciclo di test di 2 ore costa **meno di $2**. Il costo diventa un problema reale solo se lo stack resta attivo per giorni — esegui sempre `npm run cleanup` subito dopo la validazione.

---

## Cosa pesa di più

1. **FSx for Lustre** (~$168/mese) — 1200 GiB è il minimo pratico per SCRATCH_2, non esiste un tier Lustre più piccolo
2. **Redshift** (~$182.50/mese) — dc2.large è il node type più piccolo disponibile, nessuna opzione "micro"
3. **MSK** (~$62.34/mese) — 2 broker è il minimo per un cluster provisioned su 2 AZ
4. **Neptune** (~$59.86/mese) — db.t3.medium è la instance class più piccola, nessun tier "micro"
5. **DocumentDB** (~$56.21/mese) — stesso vincolo di Neptune, nessun tier "micro"
6. **ALB** ($16.43/mese) — costo fisso del load balancer anche senza traffico

---

## Raccomandazioni

1. **Distruggi subito dopo il test**: `npm run cleanup` (= `cdk destroy --force`)
2. **Non lasciare attivo per giorni** — il costo si accumula
3. **Se testi frequentemente**: usa `npm run test:full` che fa deploy+validate+destroy
4. **NAT Gateway**: abilitalo solo se devi validare lo scanner `nat-gateway`
5. **WorkSpaces**: abilitalo solo se devi validare `workspaces-idle` — è di gran lunga il costo più alto e il più lento da provisionare
6. **Free tier**: EC2 t3.micro e RDS db.t3.micro sono coperti dal free tier per i primi 12 mesi. Se il tuo account ne beneficia, il costo effettivo scende di conseguenza

---

## Perché non usiamo risorse più economiche?

- **t3.micro** è il minimo per EC2/RDS — serve un'istanza reale
- **8-10GB EBS** è il minimo ragionevole per un volume di test
- **5 RCU/WCU DynamoDB** è il minimo per provisionare (1 sarebbe troppo insolito)
- **ALB** non ha alternative più economiche — il costo base è fisso
- **dc2.large** è il node type Redshift più piccolo — non esiste un'opzione provisioned più piccola
- **db.t3.medium** è la instance class più piccola supportata da DocumentDB e Neptune — nessuno dei due offre un tier "micro"
- **1200 GiB** è il minimo pratico per FSx for Lustre SCRATCH_2 — scelto al posto di FSx for Windows proprio per evitare di richiedere un Active Directory (vedi `docs/it/ARCHITECTURE.md`)

---

## Come ridurre i costi in fase di sviluppo dello stack

Se stai iterando sullo stack CDK stesso (non sulla validazione):

```bash
# Deploy solo la parte EBS/EC2 commentando le altre sezioni
# oppure usa --exclusively per deployare solo lo stack
cdk deploy CloudriftTestStack --exclusively
```

Ricorda: ogni `cdk deploy` costa il tempo di CloudFormation + le risorse attive fino al `destroy`.
