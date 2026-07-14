# Architettura — cloudrift-cdk-test

## Obiettivo

Validare che cloudrift rilevi correttamente le risorse AWS sprecate su un account reale (non localstack), con un deployment riproducibile e a costo controllato.

---

## Decisioni di design

### CDK puro, senza Nx

| Criterio | CDK puro | Con Nx |
|----------|----------|--------|
| Complessità setup | Bassa | Alta |
| Librerie da orchestrare | 0 | 0 |
| Cache utile | No (1 target) | No |
| Tempo di setup | 2 min | 15+ min |

Conclusione: overhead ingiustificato per un progetto a singolo scopo.

### Un singolo stack

Tutte le risorse stanno in `CloudriftTestStack`. Non c'è ragione di separarle in stack diversi:
- Hanno lo stesso ciclo di vita (deploy together, destroy together)
- Non ci sono dipendenze circolari da spezzare
- Il limite di risorse CloudFormation (500) è lontanissimo

### RemovalPolicy.DESTROY ovunque

Ogni risorsa ha `removalPolicy: cdk.RemovalPolicy.DESTROY`. Questo permette `cdk destroy` senza residui. Senza di esso, CDK lascerebbe orfani i bucket S3, le log group, ecc.

### Script post-deploy per EC2/RDS "stopped"

CDK (CloudFormation) non supporta la creazione di EC2 instances o RDS instances nello stato `stopped`. Le crea `running`/`available`, e dobbiamo fermarle manualmente. Lo script `scripts/post-deploy.sh`:
1. Legge gli ID dalle output di CloudFormation
2. Ferma EC2 con `aws ec2 stop-instances` + `wait`
3. Ferma RDS con `aws rds stop-db-instance` + `wait`

### Custom Resource per EBS Snapshot orfano

cloudrift rileva gli snapshot il cui volume sorgente non esiste più. Questo non è esprimibile con risorse CDK native perché:
- Se crei un volume + snapshot nello stack, il volume esiste ancora
- Se cancelli il volume dallo stack, CloudFormation cancella anche lo snapshot (dependency)

Soluzione: una Lambda Custom Resource che:
1. Crea un volume temporaneo (fuori dal controllo CDK)
2. Ne fa uno snapshot
3. Cancella il volume
4. Risultato: snapshot con `source volume deleted`

In fase di `cdk destroy`, la stessa Lambda cancella lo snapshot (evento `Delete`).

### VPC minimale (1 AZ, 0 NAT di default)

- 1 AZ basta per tutte le risorse che servono
- 0 NAT Gateway di default (costo elevato, ~$32/mese)
- NAT abilitabile via context (`includeNatGateway: true`) per chi vuole testare anche `nat-gateway`

### Perché `--min-age-days 0` nella validazione

cloudrift ha una grace period di default di 7 giorni. Le risorse appena create non vengono segnalate. Per i test usiamo `--min-age-days 0` per disabilitarla.

---

## Mapping: risorsa → scanner cloudrift

| Risorsa CDK | ID Logico | Scanner cloudrift | Condizione di waste |
|-------------|-----------|-------------------|---------------------|
| `UnattachedGp2Volume` | EBS gp2 8GB | `ebs-volume` | `state: available` |
| `UnattachedGp3Volume` | EBS gp3 8GB | `ebs-volume` | `state: available` |
| `UnassociatedEip` | Elastic IP | `elastic-ip` | Non associato |
| `StoppedInstance` | EC2 t3.micro | `ec2-instance` | `state: stopped` |
| `IdleInstance` (root vol) | EBS gp2 10GB | `ebs-idle` | Attached, zero I/O |
| `IdleInstance` (root vol) | EBS gp2 10GB | `ebs-gp2-upgrade` | gp2 in-use |
| `StoppedRdsInstance` | RDS MySQL t3.micro | `rds-instance` | `status: stopped` |
| `EmptyAlb` | ALB | `load-balancer` | Zero target registrati |
| `NoRetentionLogGroup` | Log Group | `log-group` | Nessuna retention policy |
| `NoLifecycleBucket` | S3 Bucket | `s3-no-lifecycle` | Nessuna lifecycle config |
| `NeverInvokedLambda` | Lambda | `lambda-underutilized` | Zero invocazioni (7d) |
| `OverprovisionedTable` | DynamoDB | `dynamodb-overprovisioned` | RCU/WCU < 10% utilizzato |
| `OrphanedEni` | ENI | `eni-orphaned` | `Status: available` |
| `OrphanSnapshotCr` | EBS Snapshot | `ebs-snapshot` | Source volume deleted |
| VPC NAT Gateway (opt) | NAT | `nat-gateway` | Zero outbound traffic |

---

## Flusso operativo

```
                    cdk deploy
                        │
                        ▼
        CloudFormation crea tutte le risorse
        (EC2 e RDS nascono "running"/"available")
                        │
                        ▼
               scripts/post-deploy.sh
          Ferma EC2 → stopped
          Ferma RDS → stopped
                        │
                        ▼
              ⏳ Attendi 5-10 minuti
        (CloudWatch registra zero-traffic metrics)
                        │
                        ▼
               scripts/validate.sh
          1. Esegue: cloudrift analyze --all-services
                     --format json --min-age-days 0
          2. Parsa il JSON
          3. Verifica che ogni kind atteso sia nei findings
          4. Stampa pass/fail
                        │
                        ▼
                  cdk destroy
          (cleanup totale, nessun residuo)
```

---

## Limitazioni note

1. **`ebs-idle` e `ebs-gp2-upgrade`** richiedono che l'istanza `IdleInstance` sia running da almeno 48h per generare metriche CloudWatch a zero. Se validi subito dopo il deploy, potrebbero non comparire.

2. **`dynamodb-overprovisioned`** richiede 7 giorni di metriche a bassa utilizzazione nel default di cloudrift. Con `--min-age-days 0` il grace period è disabilitato, ma il lookback window delle metriche (168h default) potrebbe non avere abbastanza dati se la tabella è appena creata.

3. **`rds-instance`** — AWS auto-restarta le istanze RDS dopo 7 giorni di stop. Se il test dura più di una settimana senza rieseguire `post-deploy.sh`, RDS tornerà `available` e cloudrift non la troverà come `rds-instance` (ma potrebbe trovarla come `rds-underutilized`).

4. **`ec2-underutilized` e `rds-underutilized`** non sono testati qui perché richiedono `--live-pricing` (chiamate alla AWS Pricing API) e un'istanza running per 14+ giorni con CPU < 5%.
