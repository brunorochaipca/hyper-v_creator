# Criar VM Windows 10

Aplicação para criar uma máquina virtual Hyper-V com o Windows 10 22H2 já instalado. A VM arranca no ambiente de trabalho e entra com uma conta local, sem passar pelo instalador.

## Requisitos

- Windows com o Hyper-V ativo
- Permissão de administrador
- Espaço para o ISO e para um disco dinâmico de 100 GB

## Utilizar

1. Descarrega o zip da [release v1.0.0](https://github.com/brunorochaipca/hyper-v_creator/releases/tag/v1.0.0).
2. Extrai `CriarVmWindows.exe` e `win10vm.ps1` para a mesma pasta.
3. Abre o executável. O Windows pede permissão de administrador.
4. Escolhe descarregar o ISO oficial em português de Portugal ou indica um ISO que já tenhas.
5. Indica o nome da VM, a edição, o utilizador e a palavra-passe, e carrega em **Criar a VM**.

A cópia do Windows demora vários minutos. A primeira sessão mostra "A preparar o Windows" e entra sozinha. O Windows não fica ativado.

Por omissão a VM chama-se `LABWIN10`, usa a edição Windows 10 Pro, a conta `Lab` com a palavra-passe `Lab12345`, 4 GB de memória (até 8 GB), 4 processadores e o comutador **Default Switch**.

## Pela consola

Numa consola de administrador, na pasta do script:

```powershell
.\win10vm.ps1 -Client LABWIN10
.\win10vm.ps1 -Client LABWIN10 -IsoPath D:\ISO\Win10.iso
```

## Compilar

É preciso o SDK .NET 8. O executável gerado tem de ficar na mesma pasta que `win10vm.ps1`.

```powershell
dotnet publish CriarVmWindows\CriarVmWindows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```
