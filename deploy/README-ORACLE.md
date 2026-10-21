# Oracle Cloud 永久免费机 + Folia 后端（0 元，不再依赖你的电脑）

## 你已经有的东西

- SSH 公钥（粘到 Oracle 创建页面的 "Paste public keys"）：
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXofRjqQXOkaOoVujtVur2c84Ex0OYmAWpHlitN99Rx administrator@DESKTOP-QOO24T5
```
- 私钥路径（我要用它 SSH 部署）：`C:\Users\Administrator\.ssh\oracle_folia`

---

## 第 1 步：注册与创建实例（约 10 分钟）

1. 注册 https://signup.cloud.oracle.com
   - 需要邮箱 + 信用卡（只验证，不扣费；储蓄卡有时不认，建议用信用卡）
   - Home Region 选 **Japan East (Tokyo)** 或 **Singapore**（离国内近，延迟低）
2. 登录后：左上菜单 → **Compute → Instances → Create instance**
   - Name：`folia-api`
   - **Image**：`Canonical Ubuntu 24.04`（务必 Ubuntu）
   - **Shape**：`Ampere` → `VM.Standard.A1.Flex`，**2 OCPU / 12 GB**（永久免费额度内）
   - **Networking**：勾选 Assign a public IPv4 address
   - **Add SSH keys** → 选 **Paste public keys** → 粘贴上面那段公钥
   - Create
3. 创建完成后记下 **Public IP address**

> 若提示 "Out of host capacity"：换个 Availability Domain，或过几小时再试（免费 ARM 常被抢空）。

## 第 2 步：放行端口（两处都要做）

**A. 云控制台（VCN 安全列表）**
实例详情页 → Primary VNIC → Subnet → Security List → Add Ingress Rules：

```
Source 0.0.0.0/0   TCP 3210
Source 0.0.0.0/0   TCP 3211
Source 0.0.0.0/0   TCP 3212
```

**B. 实例内的 iptables（Oracle 的 Ubuntu 镜像默认拦端口）**
SSH 进去后执行：

```bash
for p in 3210 3211 3212; do sudo iptables -I INPUT 6 -p tcp --dport $p -j ACCEPT; done
sudo netfilter-persistent save
```

## 第 3 步：装后端

在实例上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/zzqwq1/Folia/main/deploy/install.sh -o install.sh
sudo bash install.sh direct
```

装完自检：

```bash
curl -s localhost:3210/search?keywords=test\&limit=1 | head -c 120; echo
curl -s localhost:3211/search?keyword=test | head -c 120; echo
```

## 第 4 步：把 IP 告我

我执行：

```
python deploy/set-backend-base.py http://IP:3210 --kugou http://IP:3211 --qq http://IP:3212
```

（改 Worker 三个常量 + **同时部署两个 Worker**，然后跑 7 项验收）

---

## 关于 QQ 音乐（重要）

Oracle 是海外 IP，QQ 音乐接口对境外 IP 有风控（code 2001），**大概率 QQ 仍然不能播**。

- 网易云、酷狗：正常
- QQ：需要国内出口（国内云 / 家里电脑）

如果 QQ 是刚需，最终仍要一台国内机器；否则这台免费机可以长期解决网易云+酷狗。

---

## 成本

| 项 | 费用 |
|---|---|
| Oracle ARM 实例 | 0 元（永久免费额度内） |
| 公网 IP | 0 元 |
| 出站流量 | 每月 10TB 免费，用不到零头 |
| 你的电脑 | 以后可以随便关 |
