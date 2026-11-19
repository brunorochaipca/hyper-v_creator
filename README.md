# Criar VM Windows 10

Aplicação para criar uma máquina virtual Hyper-V com o Windows 10 22H2 já instalado. A VM arranca no ambiente de trabalho e entra com uma conta local, sem passar pelo instalador.

## Requisitos

- Windows com o Hyper-V ativo
- Permissão de administrador
- Cerca de 5 GB de RAM livre. Se não houver, a aplicação pede para libertar memória e não inicia a VM
- Espaço para o ISO e para um disco dinâmico de 100 GB

## Instalar

Na pasta do repositório, ou depois de descarregar só o `instalar.ps1`:

```powershell
.\instalar.ps1
```

O script descarrega o `.zip` da última release, gera um MSIX assinado com um certificado desta máquina e abre-o. Se o `packaging\empacotar.ps1` e o manifesto não estiverem ao lado, vai buscá-los ao repositório. O `.msix` e o `.cer` ficam em `packaging\` e o Git ignora-os. Se faltarem o [Trust My Msix](https://github.com/Chill-Astro/Trust-My-Msix), o Windows SDK ou o App Installer, abre uma janela do PowerShell que os instala com o winget.

O Trust My Msix pede administrador e mete o certificado nas autoridades de raiz fidedignas. A aplicação continua a pedir administrador, porque cria a VM no Hyper-V. A chave privada fica em `packaging\certs` e não entra no Git.

## Utilizar

1. Extrai a pasta publicada (ou o zip da release). `CriarVmWindows.exe` e `win10vm.ps1` têm de ficar na mesma pasta.
2. Abre o executável. O Windows pede permissão de administrador.
3. Escolhe descarregar o ISO oficial em português de Portugal ou indica um ISO que já tenhas. Com um ISO próprio, a lista de edições é lida do próprio ficheiro.
4. Indica o nome da VM, o utilizador e a palavra-passe, e carrega em **Criar a VM**.
5. Acompanha os cinco passos e a percentagem da descarga. Podes cancelar a qualquer momento: o que foi criado nessa execução (VM, disco, descarga) é removido.

Antes de descarregar ou copiar o que for, o script confirma que o Hyper-V responde, que há memória livre e que as unidades envolvidas têm espaço (cerca de 20 GB para o Windows e 6 GB para o ISO). Se indicares o **SHA-256 esperado do ISO** em Opções avançadas, a criação pára se o ISO não coincidir; um ISO acabado de descarregar mostra sempre o seu SHA-256 no registo. O Fido, que obtém o link oficial da Microsoft, é descarregado de uma versão fixa (v1.72) e só corre se o SHA-256 do ficheiro for o esperado; para atualizar a versão, altera as três variáveis `$Fido…` no início do `win10vm.ps1`.

A cópia do Windows demora vários minutos. A primeira sessão mostra "A preparar o Windows" e entra sozinha. O Windows não fica ativado. No fim, **Abrir ligação à VM** abre a consola da VM e, em **Detalhes**, podes copiar ou guardar o registo (a palavra-passe não aparece nele).

Se a sessão avançada recusar a entrada («tem de ter o direito de iniciar sessão através dos Serviços de Ambiente Remoto»), carrega em **Corrigir Sessão Avançada**, no canto esquerdo do rodapé, quando a VM acabar de ser criada. A VM é desligada, a conta é posta nos Administradores e no Ambiente de Trabalho Remoto, e a VM volta a ligar-se (cerca de um a dois minutos). Se o nome da conta for igual ao da VM, o computador chama-se `NOME-PC`, porque com o mesmo nome o Windows não aceita a conta nos Administradores.

Por omissão a VM chama-se `LABWIN10`, usa a edição Windows 10 Pro, a conta `Lab` com a palavra-passe `Lab12345`, 4 GB de memória (até 8 GB), 4 processadores, disco de 100 GB e o comutador **Default Switch**. Tudo isto se altera em **Opções avançadas** (memória, processadores, disco, comutador, geração e pasta dos discos).

## Pela consola

Numa consola de administrador, na pasta do script (`src`, ou a pasta publicada):

```powershell
.\win10vm.ps1 -Client LABWIN10
.\win10vm.ps1 -Client LABWIN10 -IsoPath D:\ISO\Win10.iso
```

## Compilar

A interface é uma aplicação WinUI 3 (Windows App SDK) em .NET 10. É preciso o SDK .NET 10. A publicação gera uma pasta autónoma (o WinUI 3 não suporta ficheiro único) e já copia o `win10vm.ps1` para lá. O código fica em `src`: a interface em `src\CriarVmWindows` e o script em `src\win10vm.ps1`.

```powershell
dotnet publish src\CriarVmWindows\CriarVmWindows.csproj -c Release -p:Platform=x64 -o publish
```
