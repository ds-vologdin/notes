# Объединение в одну сеть виртуальных машины через VPP

Задача заключается в подключении виртуальных машин qemu в одну L2 сеть,
используя [протокол "vhost-user"](https://www.qemu.org/docs/master/interop/vhost-user.html).

Основное преимущество этой схемы заключается в том, что для передачи сетевых пакетов
из виртуальных машин будет происходить без передачи их в сетевой стек хостовой ОС.
Как известно, производительность сетевого стека linux не идеальна, к тому же и переключение
контекста из user в kernel space не бесплатно.

Поэтому в некоторых случаях имеет смысл использовать возможность передавать сетевые пакеты
от одного процесса другому напрямую.

## Подготовительные работы

В качестве стенда используется ubuntu 22.04, на которой установлены пакеты

- qemu-system-x86
- genisoimage
- curl

Так же нам надо установить [VPP](https://s3-docs.fd.io/vpp/24.02/).

```sh
curl -s https://packagecloud.io/install/repositories/fdio/release/script.deb.sh | sudo bash
apt-get update
apt-get install vpp vpp-plugin-core vpp-plugin-dpdk
```

_Внимание_: Не рекомендую устанавливать VPP на свою рабочую машину. После установки у меня
периодически падали приложения из snap пакетов. Coredump показывал ошибку в недрах libc,
хотя VPP его версию не меняло. Как было то ни было, куда безопаснее подобные тесты
проводить на отдельных стендах.

Дефолтные настройки vpp подразумевают складывание логов в директорию `/var/log/vpp/`, установщик которую не создает. Поэтому следует это починить

```sh
mkdir /var/log/vpp/
systemctl restart vpp
```

## Конфигурируем сеть для виртуальных машин

Воспользуемся самой простой схемой - объединим виртуальные сетевые интерфейсы в бридж.
Это максимально простое решение, естественно схема объединения виртуальных машин
в реальном мире сильно сложнее. Но предметом этой статьи не является.

```sh
vppctl create vhost-user socket /var/run/vpp/01.sock server
vppctl create vhost-user socket /var/run/vpp/02.sock server
```
У нас появились 2 сетевых интерфейса `VirtualEthernet0/0/0` и `VirtualEthernet0/0/1`.

Объединяем их в бридж

```sh
vppctl set interface l2 bridge VirtualEthernet0/0/0 1
vppctl set interface l2 bridge VirtualEthernet0/0/1 1
```

_Возможные проблемы_: мак адреса на виртуальном сетевом интерфейсе и интерфейсе на
гостевой ОС не совпадают. Кажется это не фича. В этом случае надо повесить на
виртуальный сетевой интерфейс мак адрес из гостевой ОС (или наоборот).

## Настройка памяти на хосте

vhost-user требуют использования hugetbl и shared memory. VPP будет напрямую ходить в
память гостевой ОС.

VPP при установке задает параметры ядра, на них надо критически взглянуть и возможно
увеличить некоторые значения. Например так

```sh
cat /etc/sysctl.d/80-vpp.conf
# Number of 2MB hugepages desired
vm.nr_hugepages=10240

# Must be greater than or equal to (2 * vm.nr_hugepages).
vm.max_map_count=20480

# All groups allowed to access hugepages
vm.hugetlb_shm_group=0

# Shared Memory Max must be greater or equal to the total size of hugepages.
# For 2MB pages, TotalHugepageSize = vm.nr_hugepages * 2 * 1024 * 1024
# If the existing kernel.shmmax setting  (cat /proc/sys/kernel/shmmax)
# is greater than the calculated TotalHugepageSize then set this parameter
# to current shmmax value.
kernel.shmmax=21474836480
```

после чего применим эти настройки

```sh
sysctl -p /etc/sysctl.d/80-vpp.conf
vm.nr_hugepages = 10240
vm.max_map_count = 20480
vm.hugetlb_shm_group = 0
kernel.shmmax = 21474836480
```

## Создаем образы cloud-init

В создаем файлы с конфигурацией cloud-init.


```sh
# создаем ssh ключи для доступа в виртуальную машину
ssh-keygen -t ed25519 -C "test@compute"

# создаем файлы с конфигурацией cloud-init
mkdir cloud-init

touch cloud-init/meta-data
touch cloud-init/network-config

echo "#cloud-config
user: test
password: test
chpasswd:
  expire: False
ssh_pwauth: True
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC2mkI/No5xj3fFcfvq/y3b84p8nODFbQf5sETNHwa8W test@compute
" > cloud-init/user-data

# создаем образ диска с меткой cidata
genisoimage \
    -output seed.img \
    -volid cidata -rational-rock -joliet \
    cloud-init/user-data cloud-init/meta-data cloud-init/network-config

# под каждую виртуальную машину нужен свой диск
cp seed.img seed_01.img
cp seed.img seed_02.img
```

Обратите внимание, что я передаю в гостевые машины публичный ssh ключ. Этот ключ вам
следует поменять на свой.

## Создаем виртуальные машины

```sh
# скачиваем базовый образ ubuntu
BASE_IMAGE=base.qcow2
BASE_IMAGE_URL=https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
wget $BASE_IMAGE_URL -O $BASE_IMAGE

# создаём снапшоты под каждую виртуалку
qemu-img create -f qcow2 -b $BASE_IMAGE -F qcow2 01.img 10G
qemu-img create -f qcow2 -b $BASE_IMAGE -F qcow2 02.img 10G

# запускаем виртуалки
qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -smp cpus=2 \
    -m 512m \
    -drive file=01.img,if=virtio \
    -drive file=seed_01.img,if=virtio,format=raw \
    -netdev user,id=net0,ipv6=off,restrict=off,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:22001-:22 \
    -device e1000,netdev=net0 \
    -object memory-backend-file,id=mem,size=512m,mem-path=/dev/hugepages,share=on \
    -numa node,memdev=mem -mem-prealloc \
    -chardev socket,id=chr0,path=/var/run/vpp/01.sock \
    -netdev type=vhost-user,id=net1,chardev=chr0 \
    -device virtio-net-pci,mac=00:00:00:00:00:01,netdev=net1 \
    -display none -daemonize

qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -smp cpus=2 \
    -m 512m \
    -drive file=02.img,if=virtio \
    -drive file=seed_01.img,if=virtio,format=raw \
    -netdev user,id=net0,ipv6=off,restrict=off,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:22002-:22 \
    -device e1000,netdev=net0 \
    -object memory-backend-file,id=mem,size=512m,mem-path=/dev/hugepages,share=on \
    -numa node,memdev=mem -mem-prealloc \
    -chardev socket,id=chr0,path=/var/run/vpp/02.sock \
    -netdev type=vhost-user,id=net1,chardev=chr0 \
    -device virtio-net-pci,mac=00:00:00:00:00:02,netdev=net1 \
    -display none -daemonize
```

Так мы создаем 2 машины с 2 сетевыми интерфейсами. net0 использует
[SLIRP](https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP))
для организации доступа на гостевые машины по ssh (порты 22001 и 22002 соответственно).

Второй же интерфейс будет забриджован с соседней виртуальной машиной.

Задаем сетевые адреса. Для этого мы можем подключиться на гостевые ОС по ssh. Где ssh_key файл с приватным ssh ключом (в конфигурации cloud-init мы использовали его

```sh
ssh -p 22001 -i ssh_key -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -o "ConnectTimeout=1" test@127.0.0.1

ssh -p 22002 -i ssh_key -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" -o "ConnectTimeout=1" test@127.0.0.1
```

На первой машине

```sh
ip addr add dev ens3 192.168.0.1/24
```

на второй

```sh
ip addr add dev ens3 192.168.0.2/24
```
