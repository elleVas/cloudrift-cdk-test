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

### Construct-per-concern

Lo stack monolitico è diviso in construct L3 per dominio:

| Construct | Responsabilità |
|-----------|---------------|
| `Networking` | VPC, EIP, ENI, ALB, NAT Gateway, VPN, Transit Gateway |
| `Compute` | Istanze EC2 (stopped + idle) |
| `Storage` | Volumi EBS, bucket S3, orphan snapshot CR, EFS, FSx |
| `Serverless` | Lambda, DynamoDB, CloudWatch Log Group |
| `Databases` | RDS (fermata), DocumentDB, Neptune, ElastiCache |
| `Analytics` | Redshift, OpenSearch |
| `Streaming` | Kinesis, MSK, Amazon MQ |
| `Workspaces` (opt-in) | Simple AD, WorkSpaces |

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

### Custom Resource per l'utente AD di WorkSpaces

Stesso pattern "riempi il buco" dell'orphan snapshot: CloudFormation non ha una risorsa nativa per creare un utente dentro una directory Simple AD, ma `AWS::WorkSpaces::Workspace` richiede uno `userName` già esistente. `lambda/create-ad-user` chiama l'API DirectoryServiceData (`CreateUser`/`DeleteUser`) come Custom Resource così il WorkSpace ha un utente valido a cui agganciarsi. Deployata solo se `includeWorkspaces: true`.

### FSx for Lustre, non Windows File Server

FSx for Windows File Server richiede un Active Directory (Managed Microsoft AD o self-managed) come prerequisito obbligatorio — non esiste una modalità standalone. FSx for Lustre (deployment type `SCRATCH_2`) non richiede AD, quindi lo usiamo per tenere le risorse sempre-attive (tutte tranne WorkSpaces) libere da quella dipendenza. Contropartita: la dimensione minima pratica di Lustre è 1200 GiB, più del minimo di 32 GiB che avrebbe avuto Windows — vedi `docs/it/COSTS.md`.

### VPC minimale (2 AZ, 0 NAT di default)

- 2 AZ sono il minimo per l'ALB, e vengono riusate come requisito di subnet per MSK, la directory Simple AD e i subnet group di DB/cache
- 0 NAT Gateway di default (costo elevato, ~$32/mese)
- NAT abilitabile via context (`includeNatGateway: true`) per chi vuole testare anche `nat-gateway`

### Ordinamento del deploy: MSK dipende da Analytics + Databases

MSK impiega 20+ minuti per crearsi e **non può essere cancellato mentre è in CREATING**. Se parte in parallelo con altre risorse e una di quelle fallisce, il rollback di CloudFormation si blocca per 20 minuti aspettando che MSK finisca di crearsi prima di poterlo cancellare.

Soluzione: `node.addDependency()` esplicito nel main stack, così il construct `Streaming` (che contiene MSK) parte solo dopo che `Analytics` e `Databases` sono completamente confermati. Se Redshift, OpenSearch o qualsiasi database fallisce, MSK non è ancora partito → rollback veloce e pulito.

### Redshift: ra3.xlplus, non dc2.large

`dc2.large` è stato ritirato in alcune region (in particolare eu-central-1) e fallisce con "Invalid node type". `ra3.xlplus` è il nodo ra3 più piccolo disponibile ovunque. Costa di più (~$1.09/h vs $0.25/h), ma per un ciclo deploy→validate→destroy di ~1 ora la differenza è trascurabile.

### Versione ActiveMQ: 5.18

La versione `5.17.6` è stata deprecata da AWS. Le opzioni valide sono `5.18` e `5.19` (ad luglio 2026). Usiamo `5.18` per stabilità.

### Versione RDS PostgreSQL: 16.13

La minor version pinnata deve esistere nella region di deploy. `16.4` non era disponibile in eu-central-1; `16.13` è l'ultima minor stabile nel type system CDK disponibile in tutte le region.

### Auto-detection della region negli script

Tutti gli script (`post-deploy.sh`, `validate.sh`, `concurrency-test.sh`) e i comandi in `package.json` auto-rilevano la region usando lo stesso ordine di risoluzione di CDK: `AWS_REGION` → `AWS_DEFAULT_REGION` → `aws configure get region` → fallback `us-east-1`. Questo elimina la necessità di prefissare manualmente i comandi con `AWS_REGION=...`.

### `includeWorkspaces`, opt-in e disattivato di default

Ogni altra risorsa nuova di questa estensione viene deployata sempre — il costo è stato esplicitamente escluso come vincolo per un ciclo deploy→validate→destroy di poche ore. WorkSpaces è l'unica eccezione, per un motivo diverso: una directory Simple AD impiega 20-45 minuti per raggiungere `ACTIVE` prima ancora che il WorkSpace possa essere creato, il che allunga sensibilmente l'intero ciclo rispetto a ogni altra risorsa qui presente (minuti, non decine di minuti). Abilitalo con `includeWorkspaces: true` (context o `INCLUDE_WORKSPACES=true`) solo quando ti serve specificamente validare `workspaces-idle`.

### Perché `--min-age-days 0` e `--live-pricing` nella validazione

cloudrift ha una grace period di default di 7 giorni. Le risorse appena create non vengono segnalate. Per i test usiamo `--min-age-days 0` per disabilitarla. Separatamente, 9 dei nuovi scanner (ElastiCache, Redshift, OpenSearch, MSK, DocumentDB, Neptune, MQ, WorkSpaces e `rds-underutilized`) vengono registrati solo se passi `--live-pricing` — senza questo flag non girano proprio, indipendentemente dallo stato della risorsa. È un meccanismo completamente separato dalla finestra di lookback CloudWatch che ogni scanner "idle" usa (48h di default): i datapoint mancanti valgono zero di default, quindi una risorsa idle appena creata viene rilevata immediatamente una volta che `--min-age-days 0` rimuove il grace period basato sull'età — non serve aspettare davvero che passi la finestra di lookback in tempo reale.

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
| `EmptyAlb` | ALB | `load-balancer` | Zero target registrati |
| `NoRetentionLogGroup` | Log Group | `log-group` | Nessuna retention policy |
| `NoLifecycleBucket` | S3 Bucket | `s3-no-lifecycle` | Nessuna lifecycle config |
| `NeverInvokedLambda` | Lambda | `lambda-underutilized` | Zero invocazioni (7d) |
| `OverprovisionedTable` | DynamoDB | `dynamodb-overprovisioned` | RCU/WCU < 10% utilizzato |
| `OrphanedEni` | ENI | `eni-orphaned` | `Status: available` |
| `OrphanSnapshotCr` | EBS Snapshot | `ebs-snapshot` | Source volume deleted |
| `RdsInstance` | RDS PostgreSQL 16.13, db.t3.micro | `rds-instance` | `status: stopped` |
| `UnusedEfs` | EFS | `efs-unused` | Zero mount target, o montato con zero I/O |
| `ElastiCacheCluster` | cache.t4g.micro Redis | `elasticache-idle` | Zero connessioni (`--live-pricing`) |
| `RedshiftCluster` | ra3.xlplus | `redshift-idle-cluster` | Zero connessioni (`--live-pricing`) |
| `OpenSearchDomain` | t3.small.search | `opensearch-idle-domain` | Zero traffico search/index (`--live-pricing`) |
| `MskCluster` | 2× kafka.t3.small, PROVISIONED | `msk-idle-cluster` | Zero traffico broker (`--live-pricing`) |
| `IdleFsx` | FSx for Lustre SCRATCH_2 | `fsx-idle-filesystem` | Zero I/O |
| `DocumentDbCluster` | db.t3.medium | `documentdb-idle-instance` | Zero connessioni (`--live-pricing`) |
| `NeptuneCluster` | db.t3.medium | `neptune-idle-instance` | Zero traffico query (`--live-pricing`) |
| `MqBroker` | mq.t3.micro, ActiveMQ 5.18, SINGLE_INSTANCE | `mq-idle-broker` | Zero traffico rete (`--live-pricing`) |
| `IdleVpnConnection` | VPN Site-to-Site | `vpn-connection-idle` | Zero traffico tunnel |
| `IdleTransitGatewayAttachment` | TGW + VPC attachment | `transit-gateway-idle-attachment` | Zero traffico |
| `IdleStream` | Kinesis, 1 shard, PROVISIONED | `kinesis-provisioned-idle-stream` | Zero attività in ingresso |
| `IdleWorkspace` (opt-in) | WorkSpaces, ALWAYS_ON | `workspaces-idle` | Mai connesso (`--live-pricing`) |
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
                     --format json --min-age-days 0 --live-pricing
          2. Parsa il JSON
          3. Verifica che ogni kind atteso sia nei findings
          4. Stampa pass/fail
                        │
                        ▼
                  cdk destroy
          (cleanup totale, nessun residuo)
```

Nota: `cdk deploy` e `cdk destroy` impiegano entrambi molto più tempo di prima di questa estensione — MSK, DocumentDB, Neptune, Redshift e OpenSearch impiegano ciascuno 10-20 minuti per il provisioning/distruzione (CloudFormation aspetta che ognuno raggiunga uno stato stabile). Aspettati che il ciclo completo duri 30-60 minuti anche senza `includeWorkspaces`.

---

## Limitazioni note

1. **`ebs-idle` e `ebs-gp2-upgrade`** richiedono che l'istanza `IdleInstance` sia running da almeno 48h per generare metriche CloudWatch a zero. Se validi subito dopo il deploy, potrebbero non comparire.

2. **`dynamodb-overprovisioned`** richiede 7 giorni di metriche a bassa utilizzazione nel default di cloudrift. Con `--min-age-days 0` il grace period è disabilitato, ma il lookback window delle metriche (168h default) potrebbe non avere abbastanza dati se la tabella è appena creata.

3. **`rds-instance`** — AWS auto-restarta le istanze RDS dopo 7 giorni di stop. Se il test dura più di una settimana senza rieseguire `post-deploy.sh`, RDS tornerà `available` e cloudrift non la troverà come `rds-instance`.

4. **`ec2-underutilized` e `rds-underutilized`** non sono testati qui. Entrambi usano MAX(CPU) su una finestra di lookback *fissa* di 168h (`utilizationWindowHours`), non una media mobile. Un'istanza EC2/RDS appena creata ha un genuino spike di CPU durante il boot/inizializzazione, e quello spike resta dentro la finestra di 168h — quindi continua a far fallire la condizione `max CPU < 5%` — per 7 giorni pieni dopo la creazione, indipendentemente da quanto tempo l'istanza resti idle dopo. Non c'è modo di far scattare questi due scanner in un ciclo breve deploy→validate→destroy.

5. **`mq-idle-broker`**: il broker Amazon MQ deve raggiungere lo stato `RUNNING` prima di riportare metriche — può richiedere diversi minuti dopo la fine di `cdk deploy`, più a lungo della maggior parte degli altri scanner qui presenti.

6. **Bundle ID di WorkSpaces** (`lib/constructs/workspaces.ts`): `VALUE_BUNDLE_ID_BY_REGION` ha un bundle ID pubblico "Value" hardcoded per region. AWS li cambia nel tempo — se `cdk deploy` fallisce con un errore di bundle non valido, cerca l'ID corrente per la tua region e aggiorna la mappa.

7. **Creazione utente AD di WorkSpaces** (`lambda/create-ad-user/index.js`): scritta sulla base della conoscenza generale dell'API DirectoryServiceData (`CreateUser`/`DeleteUser`), non verificata con un deploy reale. Controlla i log CloudWatch della Lambda al primo utilizzo con `includeWorkspaces: true` e correggi la forma della chiamata API se fallisce.

8. **Pricing throughput-capacity di FSx**: la stima di costo per `IdleFsx` (FSx for Lustre) in `docs/it/COSTS.md` è una stima best-effort, non verificata indipendentemente contro il pricing AWS attuale — controlla la prima bolletta prima di considerarla accurata per la pianificazione.
