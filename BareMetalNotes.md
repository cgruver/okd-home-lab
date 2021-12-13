```bash
brew install qemu
brew install autoconf
brew install automake
brew install wolfssl

mkdir -p ${OKD_LAB_PATH}/work-dir
cd ${OKD_LAB_PATH}/work-dir
git clone https://github.com/virtualsquare/vde-2.git
cd vde-2
autoreconf -fis
./configure --prefix=/opt/vde
make
sudo make install

cd ..
git clone https://github.com/lima-vm/vde_vmnet
cd vde_vmnet
make PREFIX=/opt/vde
sudo make PREFIX=/opt/vde install
sudo make install BRIDGED=en0
cd
rm -rf ${OKD_LAB_PATH}/work-dir

mkdir -p ${OKD_LAB_PATH}/bootstrap
qemu-img create -f qcow2 ${OKD_LAB_PATH}/bootstrap/bootstrap-node.qcow2 50G

BOOTSTRAP_BRIDGE=en6

qemu-system-x86_64 -accel accel=hvf -m 12G -smp 2 -display none -nographic -drive file=${OKD_LAB_PATH}/bootstrap/bootstrap-node.qcow2,if=none,id=disk1  -device ide-hd,bus=ide.0,drive=disk1,id=sata0-0-0,bootindex=1 -boot n -netdev vde,id=nic0,sock=/var/run/vde.bridged.${BOOTSTRAP_BRIDGE}.ctl -device virtio-net-pci,netdev=nic0,mac=52:54:00:a1:b2:c3

launchctl unload -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.bridged.en6.plist"
launchctl unload -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.bridged.en6.plist"
launchctl unload -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.plist"
launchctl unload -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.plist"

launchctl load -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.plist"
launchctl load -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.plist"
launchctl load -w "/Library/LaunchDaemons/io.github.virtualsquare.vde-2.vde_switch.bridged.en6.plist"
launchctl load -w "/Library/LaunchDaemons/io.github.lima-vm.vde_vmnet.bridged.en6.plist"

  disks:
    - device: /dev/${boot_dev}
      partitions:
        - label: root
          number: 4
          size_mib: 0
          resize: true

systemd:
   units:
     - name: hyper-thread.service
       enabled: true
       contents: |
         [Unit]
         Description=Enable HyperThreading
         Before=kubelet.service
         After=systemd-machine-id-commit.service
         ConditionKernelCommandLine=mitigations
         
         [Service]
         Type=oneshot
         RemainAfterExit=yes
         ExecStart=/bin/rpm-ostree kargs --replace="mitigations=auto" --reboot
         [Install]
         RequiredBy=kubelet.service
         WantedBy=multi-user.target

kill $(ps -ef | grep qemu | grep bootstrap | awk '{print $2}')

for i in 0 1 2
do
  ssh core@okd4-master-${i}.${SUB_DOMAIN}.${LAB_DOMAIN} "sudo rpm-ostree kargs --replace=\"mitigations=auto,nosmt=auto\""
done

for i in 0 1 2
do
  ssh core@okd4-master-${i}.${SUB_DOMAIN}.${LAB_DOMAIN} "sudo systemctl reboot"
  sleep 30
done

for i in 0 1 2
do
  ssh core@okd4-worker-${i}.${SUB_DOMAIN}.${LAB_DOMAIN} "sudo rpm-ostree kargs --replace=\"mitigations=auto,nosmt=auto\" --delete-if-present=\"mitigations=off\" --reboot"
done

```
