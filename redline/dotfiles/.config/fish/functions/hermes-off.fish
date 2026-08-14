function hermes-off --description 'Stop the sandboxed Hermes Agent VM'
    virsh -c qemu:///system destroy hermes
end