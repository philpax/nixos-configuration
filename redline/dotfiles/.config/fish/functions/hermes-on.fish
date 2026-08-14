function hermes-on --description 'Start the sandboxed Hermes Agent VM'
    virsh -c qemu:///system start hermes
end