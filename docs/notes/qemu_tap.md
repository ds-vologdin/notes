# Использование tap интерфейсов в qemu

Здесь будет рассмотрен базовый сценарий подключения tap сетевого интерфейса
к виртуальной машине. Проведены замеры пропускной способности между гостевой
и хостовой ОС.

## Подготовка

Скачаем базовый образ [cirros](https://github.com/cirros-dev/cirros). Он хорош в первую
очередь своим размером.

```sh
wget http://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
```

Создадим снапшоты для виртуальных машин из базового образа

```sh
qemu-img create -f qcow2 -b cirros-0.6.2-x86_64-disk.img -F qcow2 vm.img 10G
```

Напишем скрипты для конфигурирования `tap` устройства при его создании и удалении,
которые будет использовать qemu

Скрипт `up_tap.sh` просто добавляет сетевой интерфейс и вешает на него адрес

```bash
#!/bin/bash

IF=$1
ip tuntap add $IF mode tap
ip add add 192.168.15.254/24 dev $IF
ip link set up $IF
```

и скрипт удаления tap интерфейса `down_tap.sh`

```bash
#!/bin/bash

IF=$1
echo "down interface $IF"
ip tuntap del $IF mod tap
```

На гостевой операционной системе мы сконфигурируем сетевые интерфейсы вручную.

## Работа с vhost

Vhost позволяет передавать сетевые пакеты напрямую из гостевой в хостовую ОС,
минуя qemu.

### Запуск виртуальной машин

```sh
qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -smp cpus=2 \
    -m 512m \
    -drive file=vm.img,if=virtio \
    -netdev tap,ifname=tap-1,vhost=on,id=net1,script=./up_tap.sh,downscript=./down_tap.sh \
    -device virtio-net-pci,netdev=net1
```

Виртуальная машина запустится и в неё можно залогиниться с учетной `cirros` и паролем `gocubsgo`.

> После первого запуска можно в файле /etc/cirros-init/config можно закомментировать
строку с настройкой `DATASOURCE_LIST`. Что ускорит последующие запуски, поскольку cloud-init
не будет пытаться подключиться к IMDService.

### Тест пропускной способности

Запускаем на хосте `iperf3`

```sh
iperf3 -s
```

В консоли виртуальной машины настраиваем сеть

```sh
ip a a 192.168.15.2 dev eth0
```

Сейчас с гостевой ОС доступна хостовая система по адресу `192.168.15.254`.
Запускаем тест

```sh
iperf3 -c 192.168.15.254
```

И на сервере получаем отчет.

```sh
Accepted connection from 192.168.15.2, port 52688
[  5] local 192.168.15.254 port 5201 connected to 192.168.15.2 port 52700
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-1.00   sec  6.92 GBytes  59.5 Gbits/sec                  
[  5]   1.00-2.00   sec  6.94 GBytes  59.6 Gbits/sec                  
[  5]   2.00-3.00   sec  7.08 GBytes  60.8 Gbits/sec                  
[  5]   3.00-4.00   sec  7.06 GBytes  60.7 Gbits/sec                  
[  5]   4.00-5.00   sec  6.88 GBytes  59.1 Gbits/sec                  
[  5]   5.00-6.00   sec  6.89 GBytes  59.2 Gbits/sec                  
[  5]   6.00-7.00   sec  7.08 GBytes  60.8 Gbits/sec                  
[  5]   7.00-8.00   sec  7.08 GBytes  60.8 Gbits/sec                  
[  5]   8.00-9.00   sec  6.95 GBytes  59.7 Gbits/sec                  
[  5]   9.00-10.00  sec  7.05 GBytes  60.5 Gbits/sec                  
[  5]  10.00-10.04  sec   295 MBytes  59.3 Gbits/sec                  
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-10.04  sec  70.2 GBytes  60.1 Gbits/sec                  receiver
```

## Работа без vhost

А сейчас попробуем отключить vhost и посмотрим на сколько сильно это повлияет на
пропускную способность.

### Запуск виртуальной машины без vhost

Выключаем виртуальную машину и запускаем снова с отключенной опцией `vhost`.

```sh
qemu-system-x86_64 \
    -machine accel=kvm:tcg \
    -smp cpus=2 \
    -m 512m \
    -drive file=vm.img,if=virtio \
    -netdev tap,ifname=tap-1,vhost=off,id=net1,script=./up_tap.sh,downscript=./down_tap.sh \
    -device virtio-net-pci,netdev=net1
```

После запуска конфигурируем аналогично тому как делали это раньше

```sh
ip a a 192.168.15.2 dev eth0
```

### Тест пропускной способности без vhost

Повторяем замер скорости и видим, что без `vhost`, как и ожидалось, пропускная способность
заметно ниже. Схема с отключенным vhost в моем тесте показала снижение пропускной
способности на 24%.

```sh
Accepted connection from 192.168.15.2, port 52336
[  5] local 192.168.15.254 port 5201 connected to 192.168.15.2 port 52340
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-1.00   sec  4.82 GBytes  41.4 Gbits/sec                  
[  5]   1.00-2.00   sec  5.18 GBytes  44.5 Gbits/sec                  
[  5]   2.00-3.00   sec  5.45 GBytes  46.8 Gbits/sec                  
[  5]   3.00-4.00   sec  5.33 GBytes  45.8 Gbits/sec                  
[  5]   4.00-5.00   sec  5.17 GBytes  44.4 Gbits/sec                  
[  5]   5.00-6.00   sec  5.41 GBytes  46.4 Gbits/sec                  
[  5]   6.00-7.00   sec  5.44 GBytes  46.7 Gbits/sec                  
[  5]   7.00-8.00   sec  5.40 GBytes  46.4 Gbits/sec                  
[  5]   8.00-9.00   sec  5.41 GBytes  46.5 Gbits/sec                  
[  5]   9.00-10.00  sec  5.37 GBytes  46.1 Gbits/sec                  
[  5]  10.00-10.04  sec   207 MBytes  45.3 Gbits/sec                  
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate
[  5]   0.00-10.04  sec  53.2 GBytes  45.5 Gbits/sec                  receiver
```

## Дополнительные ссылки

- [Introduction to virtio-networking and vhost-net](https://www.redhat.com/en/blog/introduction-virtio-networking-and-vhost-net)
- [Deep dive into Virtio-networking and vhost-net](https://www.redhat.com/en/blog/deep-dive-virtio-networking-and-vhost-net)
- [Virtio devices and drivers overview: The headjack and the phone](https://www.redhat.com/en/blog/virtio-devices-and-drivers-overview-headjack-and-phone)
- [Virtqueues and virtio ring: How the data travels](https://www.redhat.com/en/blog/virtqueues-and-virtio-ring-how-data-travels)
