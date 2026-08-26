# 로컬 → 클라우드 배포 가이드

H.A.C.K 자녀보호앱(careguard)을 로컬 개발 환경에서 AWS로 올릴 때 무엇이 바뀌는지와,
실제 배포 절차를 정리한 문서입니다.

- **서비스 주소**: https://kidhackapp.com
- **리전**: ap-northeast-2 (서울)
- **인프라 코드**: `3. 개발/hack_terraform`

---

## 1. 한눈에 보는 구조 변화

로컬에서는 프로세스 3개가 한 노트북 안에서 `localhost`로 통신합니다.
클라우드에서는 같은 역할이 AZ 2개에 이중화되어 흩어집니다.

| | 로컬 | 클라우드 |
|---|---|---|
| 프론트 | `vite dev` (:5173) | Nginx 정적 서빙 (WEB EC2 ×2) |
| 백엔드 | `bootRun` (:8080) | `java -jar` + systemd (WAS EC2 ×2) |
| RDB | H2 인메모리 | RDS Oracle SE2 (Multi-AZ) |
| NoSQL | 로컬 MongoDB | DocumentDB (인스턴스 2대) |
| 캐시 | 로컬 Redis | ElastiCache Redis (Multi-AZ) |
| 파일 | 로컬 디스크 | S3 (**앱 코드 수정 필요**, 5장 참고) |
| 진입점 | 브라우저 → localhost | 사용자 → ALB(HTTPS) → Nginx → NLB → WAS |

가장 중요한 변화 세 가지입니다.

1. **WAS가 2대**입니다. 요청이 어느 쪽으로 갈지 알 수 없으므로, 인스턴스의 로컬 상태에
   의존하는 코드는 전부 깨집니다. (세션은 Redis로 공유되지만 업로드 파일은 아직 아닙니다)
2. **DB 3종이 전부 TLS**입니다. 로컬은 평문이었습니다.
3. **H2가 사라집니다.** 실제 Oracle로 바뀌므로 SQL 방언 차이가 드러날 수 있습니다.

---

## 2. 백엔드: 무엇이 어떻게 바뀌는가

`application.yml`은 **수정하지 않습니다.** WAS 부팅 시 `/opt/app/app.env`에 환경변수를
써서 덮어쓰는 방식입니다(Spring Boot relaxed binding). 로컬 개발이 그대로 유지됩니다.

| `application.yml` (로컬) | 클라우드에서 덮어쓰는 환경변수 |
|---|---|
| `jdbc:h2:mem:kidhackdb;MODE=Oracle` | `SPRING_DATASOURCE_URL=jdbc:oracle:thin:@//<rds>/ORCL` |
| `org.h2.Driver` | `SPRING_DATASOURCE_DRIVER_CLASS_NAME=oracle.jdbc.OracleDriver` |
| `sa` / (빈 비밀번호) | `SPRING_DATASOURCE_USERNAME/PASSWORD` ← SSM에서 조회 |
| `h2.console.enabled: true` | `SPRING_H2_CONSOLE_ENABLED=false` |
| — | `SPRING_JPA_DATABASE_PLATFORM=org.hibernate.dialect.OracleDialect` |
| `mongodb://localhost:27017/...` | `SPRING_DATA_MONGODB_URI=mongodb://...?tls=true&replicaSet=rs0&retryWrites=false` |
| `redis. host: localhost` | `SPRING_DATA_REDIS_HOST=<elasticache>` + `SPRING_DATA_REDIS_SSL_ENABLED=true` |
| `jwt.secret: local-test-...` | `JWT_SECRET` ← Terraform이 생성한 64자 난수, SSM에서 조회 |
| — | `SERVER_FORWARD_HEADERS_STRATEGY=framework` |

### 왜 이런 값들이 필요한가

**`retryWrites=false` (DocumentDB)**
DocumentDB는 재시도 가능 쓰기를 지원하지 않는데, MongoDB Java 드라이버 4.2+는 이걸
기본으로 켭니다. 빼면 쓰기마다 실패합니다. 가장 흔한 함정입니다.

**`replicaSet=rs0` (DocumentDB)**
DocumentDB의 레플리카셋 이름은 항상 `rs0` 고정입니다. 이걸 붙이면 드라이버가 토폴로지를
발견해 쓰기는 Writer로, 읽기는 `readPreference`대로 보냅니다. 페일오버도 자동 추종합니다.

**`SPRING_DATA_REDIS_SSL_ENABLED=true`**
ElastiCache에 전송 암호화가 켜져 있어 TLS로만 접속됩니다. 이 값이 없으면
포트가 열려 있어도 접속에 실패합니다. **SG 문제로 착각하기 쉬운 장애**입니다.

**`SERVER_FORWARD_HEADERS_STRATEGY=framework`**
ALB → Nginx → NLB → WAS로 프록시가 2단입니다. Spring Boot는 기본적으로
`X-Forwarded-Proto`를 무시하므로(`NONE`), 이 값이 없으면 리다이렉트가 `http://`로
생성되어 무한 리다이렉트가 발생합니다.

**DocumentDB 인증서**
DocumentDB는 Amazon RDS CA(프라이빗 CA)가 발급한 인증서를 씁니다. JDK 기본
`cacerts`에 없어서 그대로는 연결이 안 됩니다. 부팅 스크립트가 JDK의 `cacerts`를
**복사한 뒤** RDS 번들을 추가합니다. 복사가 아니라 새로 만들면 퍼블릭 CA가 사라져
**Redis TLS가 깨집니다.**

### 비밀 값 관리

DB 비밀번호와 JWT 키는 SSM Parameter Store(SecureString)에 있고, WAS가 부팅 시
IAM 역할로 복호화해 가져옵니다. `user_data`에 넣지 않은 이유는 인스턴스 메타데이터로
평문 노출되어 인스턴스 내 아무 프로세스나 읽을 수 있기 때문입니다.

| 파라미터 | 용도 |
|---|---|
| `/kidhackapp/rds/password` | Oracle 마스터 |
| `/kidhackapp/docdb/password` | DocumentDB 마스터 |
| `/kidhackapp/app/jwt-secret` | JWT 서명 키 (Terraform 자동 생성) |

---

## 3. 프론트엔드: 무엇이 어떻게 바뀌는가

| | 로컬 | 클라우드 |
|---|---|---|
| 실행 | `npm run dev` (:5173) | 빌드 산출물 `dist/`를 Nginx가 서빙 |
| `VITE_USE_MOCK` | `true` (목 데이터) | `false` |
| `VITE_API_BASE_URL` | (목 사용 시 무관) | **`/api`** |

### `VITE_API_BASE_URL`을 `/api`로 두는 이유

`.env.example`에는 `https://api.childsafe.example.com/api`로 되어 있는데, **별도 도메인을
쓰면 CORS 설정이 추가로 필요합니다.** 같은 도메인에서 Nginx가 `/api/`를 내부 NLB로
프록시하므로 상대 경로를 쓰면 CORS가 아예 발생하지 않습니다.

백엔드 컨트롤러가 이미 `@RequestMapping("/api/...")`로 매핑되어 있고 `context-path`가
없으므로, Nginx는 경로를 **변형 없이 그대로** 전달합니다.

### ⚠️ Vite 환경변수는 빌드 시점에 박힙니다

`VITE_*` 값은 빌드할 때 코드에 치환되어 들어갑니다. **런타임에 바꿀 수 없습니다.**
`.env`를 고쳤으면 반드시 다시 빌드해야 합니다.

### 권장: 로컬 dev에도 프록시 추가

현재 `vite.config.ts`에는 프록시가 없어서, 로컬에서 `VITE_USE_MOCK=false`로 실제
백엔드를 붙이면 CORS에 막힙니다. 아래를 추가하면 **로컬과 클라우드의 코드 경로가
같아집니다.**

```ts
// vite.config.ts
server: {
  port: 5173,
  open: false,
  proxy: {
    '/api': { target: 'http://localhost:8080', changeOrigin: true },
  },
},
```

---

## 4. 모바일

**모바일 앱은 서버에 배포되지 않습니다.** 인프라와 무관한 클라이언트입니다.
필요한 설정은 API 주소 하나뿐입니다.

```
https://kidhackapp.com
```

웹과 달리 **절대 URL**을 써야 합니다(같은 오리진이 아니므로). 네이티브 앱이라 CORS는
발생하지 않습니다.

- **Android 9(API 28) 이상은 평문 HTTP를 기본 차단**합니다. HTTPS 구성이 되어 있어야
  API 호출이 됩니다.
- ACM 인증서는 Amazon(퍼블릭 CA) 발급이라 Android·iOS 기본 신뢰 저장소에 이미
  있습니다. 앱에 인증서를 심는 작업이 필요 없습니다.

---

## 5. ⚠️ 코드 수정이 필요한 항목

인프라 설정으로 해결되지 않아 **앱 코드를 고쳐야 하는** 것들입니다.

### 5-1. 파일 업로드 (중요)

```yaml
file:
  upload-dir: uploads/community
  inquiry-upload-dir: uploads/inquiry
```

WAS가 2대인데 업로드 파일이 **요청을 처리한 인스턴스의 로컬 디스크**에 저장됩니다.

- WAS1에 올린 파일을 WAS2가 서빙할 수 없습니다 (요청마다 다른 인스턴스로 갑니다)
- 인스턴스를 재생성하면 파일이 사라집니다

S3 버킷과 IAM 권한(`s3:PutObject`, `s3:GetObject`)은 **이미 준비되어 있습니다.**
`@Value("${file.upload-dir}")`를 쓰는 서비스 클래스를 S3 SDK 호출로 바꾸면 됩니다.

### 5-2. `ddl-auto: update` 확인

로컬 H2는 `MODE=Oracle`이었을 뿐 실제 Oracle이 아닙니다. Hibernate가 Oracle에
스키마를 자동 생성할 때 예약어·타입 매핑 차이로 실패할 수 있습니다.
**첫 배포 후 반드시 로그를 확인하세요.**

운영 전환 시에는 `ddl-auto: validate`로 바꾸고 스키마를 별도 관리하는 것이 안전합니다.

### 5-3. (선택) Actuator 추가

현재 NLB 헬스체크가 **TCP**라 포트만 열려 있으면 정상으로 판정합니다. DB 연결이
끊겨 앱이 마비돼도 `healthy`로 보입니다.

`spring-boot-starter-actuator`를 추가하면 헬스체크를 HTTP `/actuator/health`로
바꿀 수 있습니다. (Terraform의 `was_tg` 헬스체크도 함께 수정 필요)

---

## 6. 배포 절차

### 6-1. 인프라 (최초 1회 또는 destroy 후)

```bash
cd "3. 개발/hack_terraform"
terraform init
terraform apply        # 30~40분 (RDS Oracle Multi-AZ가 대부분)
```

호스팅 존은 Terraform 밖에서 관리되므로(`data` 참조) destroy해도 남습니다.
`kidhackapp.com`은 Route 53에서 등록한 도메인이라 네임서버가 자동 연결되어 있습니다.
**등록기관에서 손으로 할 설정이 없습니다.**

### 6-2. 프론트엔드 빌드 & 업로드

```bash
cd "3. 개발/web"
printf "VITE_USE_MOCK=false\nVITE_API_BASE_URL=/api\n" > .env
npm ci
npm run build
tar -czf dist.tar.gz dist      # ⚠️ dist/ 디렉터리가 한 겹 있어야 함

aws s3 cp dist.tar.gz s3://kidhackapp-media-bucket-2026/artifacts/web/dist.tar.gz
```

> **tar 구조 주의**: 부팅 스크립트가 `--strip-components=1`로 풀기 때문에
> `tar -czf dist.tar.gz dist` 형태여야 합니다.
> `cd dist && tar -czf ../dist.tar.gz .` 로 만들면 파일이 전부 사라집니다.

### 6-3. 백엔드 빌드 & 업로드

```bash
cd "3. 개발/backend"
./gradlew bootJar
ls build/libs/
```

```
kidhack-backend-0.0.1-SNAPSHOT.jar         ← ✅ 이것
kidhack-backend-0.0.1-SNAPSHOT-plain.jar   ← ❌ 클래스만 든 껍데기
```

> `-plain.jar`를 올리면 `no main manifest attribute`로 죽습니다.

```bash
aws s3 cp build/libs/kidhack-backend-0.0.1-SNAPSHOT.jar \
  s3://kidhackapp-media-bucket-2026/artifacts/was/kidhack-backend.jar
```

**파일명을 `kidhack-backend.jar`로 바꿔서** 올려야 합니다. 부팅 스크립트가 이 이름을
하드코딩합니다.

### 6-4. 서비스 반영

**WAS는 아무것도 안 해도 됩니다.** jar가 없으면 30초마다 재시도하고 있으므로,
S3에 올리는 순간 자동으로 기동됩니다.

**WEB만** 한 번 눌러줍니다. SSM Session Manager로 접속 후:

```bash
sudo systemctl start careguard-sync
```

### 재배포 (2회차부터)

인스턴스를 재생성할 필요가 없습니다.

```bash
# 백엔드
./gradlew bootJar && aws s3 cp build/libs/*-SNAPSHOT.jar s3://.../artifacts/was/kidhack-backend.jar
# WAS에서
sudo systemctl restart kidhack

# 프론트
npm run build && tar -czf dist.tar.gz dist && aws s3 cp dist.tar.gz s3://.../artifacts/web/dist.tar.gz
# WEB에서
sudo systemctl start careguard-sync
```

---

## 7. 검증

```bash
# 출력값
terraform output

# HTTPS / 리다이렉트
curl -I https://kidhackapp.com          # 200
curl -I http://kidhackapp.com           # 301 → https

# 타깃 헬스
aws elbv2 describe-target-health --target-group-arn \
  $(aws elbv2 describe-target-groups --names kidhackapp-was-tg \
    --query "TargetGroups[0].TargetGroupArn" --output text)
```

| 상태 | 의미 |
|---|---|
| WEB `healthy`, 화면에 `bootstrapping` | dist 미업로드 (정상, 6-2 진행) |
| WAS `unhealthy`, `/api` → 502 | jar 미업로드 (정상, 6-3 진행) |
| WAS `healthy` | 앱 정상 기동 |

---

## 8. 트러블슈팅

부팅 로그가 1차 단서입니다. SSM Session Manager로 접속 후:

```bash
sudo cat /var/log/user-data.log       # 부팅 스크립트
sudo journalctl -u kidhack -n 100     # 백엔드 (WAS)
sudo journalctl -u careguard-sync     # 프론트 동기화 (WEB)
```

| 증상 | 원인 |
|---|---|
| `no main manifest attribute` | `-plain.jar`를 올림 |
| Redis 연결 실패 (포트는 열림) | `SPRING_DATA_REDIS_SSL_ENABLED` 누락 |
| `PKIX path building failed` | DocumentDB 트러스트스토어 구성 실패 |
| DocumentDB 쓰기 실패 | `retryWrites=false` 누락 |
| `ORA-12514` | Oracle SID 불일치 (`var.oracle_db_name`) |
| 무한 리다이렉트 | `SERVER_FORWARD_HEADERS_STRATEGY` 누락 |
| 새로고침 시 404 | Nginx `try_files` 폴백 문제 (SPA 라우팅) |
| 화면은 뜨는데 API만 502 | WAS가 안 떠 있음 → `journalctl -u kidhack` |

---

## 9. 비용과 정리

**시간당 약 $1 (하루 $20~25)** 수준입니다. 비중이 큰 순서:

1. RDS Oracle SE2 Multi-AZ (라이선스 포함) — 압도적 1위
2. NAT Gateway 2대
3. DocumentDB 2대
4. EC2 4대 + ALB + NLB

**작업하지 않을 때는 destroy하세요.**

```bash
terraform destroy
```

- `keep_final_snapshot = false`(기본)이면 스냅샷 없이 빠르게 정리됩니다.
  최종 제출 시점에만 `true`로 바꾸세요.
- 호스팅 존은 남습니다 → 다시 `apply`하면 도메인이 그대로 살아납니다.
- **S3 버킷은 산출물까지 전부 삭제됩니다.** 버킷에 `force_destroy = true`가 걸려 있습니다.
  이 옵션이 없으면 버저닝 때문에 `BucketNotEmpty`로 destroy 자체가 실패합니다.
  따라서 재배포 시 `dist.tar.gz`와 jar를 다시 올려야 합니다 (6-2, 6-3).

프로젝트를 완전히 종료할 때는 콘솔에서 Route 53 호스팅 존(월 $0.50)을 직접 삭제하세요.

---

## 10. 아직 남은 과제

| 항목 | 비고 |
|---|---|
| 파일 업로드 S3 전환 | 5-1, **앱 코드 수정** |
| Auto Scaling Group | 비용 제약으로 의도적 미구현. EC2 장애 시 자가 복구 없음 |
| Actuator 헬스체크 | 5-3 |
| `tfstate` 원격 백엔드 | 현재 로컬 저장, 비밀 값이 평문으로 포함됨. `git init` 전 정리 필요 |
| WEB↔WAS 내부 구간 암호화 | VPC 내부 평문 (외부 구간은 HTTPS 완료) |
