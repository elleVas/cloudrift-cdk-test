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
| RDS storage 20GB gp2 (stopped) | Storage | — | $0.077 | $2.30 |
| ALB (no targets) | Network | $0.0225 | $0.54 | $16.43 |
| Log Group (no retention) | Logs | $0.00 | $0.00 | $0.00* |
| S3 Bucket (empty, no lifecycle) | Storage | $0.00 | $0.00 | $0.00 |
| Lambda (never invoked) | Compute | $0.00 | $0.00 | $0.00 |
| DynamoDB (5 RCU + 5 WCU) | Database | — | $0.10 | $3.11 |
| ENI (orphaned) | Network | $0.00 | $0.00 | $0.00 |
| EBS Snapshot 1GB | Storage | — | $0.002 | $0.05 |
| **NAT Gateway** (opzionale) | Network | $0.045 | $1.08 | $32.85 |

*Log Group: costa $0.03/GB ingested — con zero log scritti, costo zero.

---

## Totali

| Scenario | Costo/giorno | Costo/settimana | Costo/mese |
|----------|-------------|-----------------|------------|
| **Senza NAT Gateway** | ~$1.20 | ~$8.40 | ~$36.16 |
| **Con NAT Gateway** | ~$2.28 | ~$15.96 | ~$69.01 |

---

## Cosa pesa di più

1. **ALB** ($16.43/mese) — costo fisso del load balancer anche senza traffico
2. **EC2 running** ($7.59/mese) — l'istanza idle (serve per testare `ebs-idle`)
3. **EIP** ($3.60/mese) — costo fisso per IP non associato
4. **DynamoDB** ($3.11/mese) — provisioned capacity inutilizzata
5. **RDS storage** ($2.30/mese) — storage billed anche se l'istanza è stopped

---

## Raccomandazioni

1. **Distruggi subito dopo il test**: `npm run cleanup` (= `cdk destroy --force`)
2. **Non lasciare attivo per giorni** — il costo si accumula
3. **Se testi frequentemente**: usa `npm run test:full` che fa deploy+validate+destroy
4. **NAT Gateway**: abilitalo solo se devi validare lo scanner `nat-gateway`
5. **Free tier**: EC2 t3.micro e RDS db.t3.micro sono coperti dal free tier per i primi 12 mesi. Se il tuo account ne beneficia, il costo effettivo scende a ~$0.70/giorno

---

## Perché non usiamo risorse più economiche?

- **t3.micro** è il minimo per EC2/RDS — serve un'istanza reale
- **8-10GB EBS** è il minimo ragionevole per un volume di test
- **5 RCU/WCU DynamoDB** è il minimo per provisionare (1 sarebbe troppo insolito)
- **ALB** non ha alternative più economiche — il costo base è fisso

---

## Come ridurre i costi in fase di sviluppo dello stack

Se stai iterando sullo stack CDK stesso (non sulla validazione):

```bash
# Deploy solo la parte EBS/EC2 commentando le altre sezioni
# oppure usa --exclusively per deployare solo lo stack
cdk deploy CloudriftTestStack --exclusively
```

Ricorda: ogni `cdk deploy` costa il tempo di CloudFormation + le risorse attive fino al `destroy`.
