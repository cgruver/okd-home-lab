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

qemu-system-x86_64 -accel accel=hvf -m 12G -smp 2 -display none -nographic -drive file=${OKD_LAB_PATH}/bootstrap/bootstrap-node.qcow2,if=virtio -boot n -netdev vde,id=nic0,sock=/var/run/vde.bridged.en13.ctl -device virtio-net-pci,netdev=nic0
```
