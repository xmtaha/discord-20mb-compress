param(
    [switch]$SelfTest,
    [string]$EngineTest
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# Yüksek DPI'da bulanıklaşmayı önle
try {
    Add-Type -Namespace Native -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][Native.Dpi]::SetProcessDPIAware()
} catch { }

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
#  MOTOR (ayri runspace'te calisir)
# ============================================================
$engineCode = @'
param($Queue, $State, $Files, $Options, $BaseDir)

function Send($o) { $Queue.Enqueue($o) }

$TargetMB  = [double]$Options.TargetMB
$AudioKBPS = [int]$Options.AudioKBPS
$Quality   = [string]$Options.Quality
$ResMode   = [string]$Options.Resolution

function Find-Tool($name) {
    $p = Join-Path $BaseDir $name
    if (Test-Path $p) { return $p }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:FFmpeg  = Find-Tool 'ffmpeg.exe'
$script:FFprobe = Find-Tool 'ffprobe.exe'

if (-not $script:FFmpeg -or -not $script:FFprobe) {
    Send @{Type='log'; Text='ffmpeg bulunamadi, indiriliyor... (ilk sefer, birkac dakika surebilir)'}
    try {
        $zip = Join-Path $BaseDir 'ffmpeg.zip'
        $url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Send @{Type='log'; Text='Indirme bitti, cikariliyor...'}
        Expand-Archive -Path $zip -DestinationPath $BaseDir -Force
        Remove-Item $zip -Force
        $ex = Get-ChildItem $BaseDir -Directory | Where-Object Name -like 'ffmpeg-*' | Sort-Object Name -Descending | Select-Object -First 1
        if ($ex) {
            Copy-Item (Join-Path $ex.FullName 'bin\*.exe') $BaseDir -Force
            Remove-Item $ex.FullName -Recurse -Force
        } else {
            Copy-Item (Join-Path $BaseDir 'bin\*.exe') $BaseDir -Force
            Remove-Item (Join-Path $BaseDir 'bin') -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:FFmpeg  = Join-Path $BaseDir 'ffmpeg.exe'
        $script:FFprobe = Join-Path $BaseDir 'ffprobe.exe'
        Send @{Type='log'; Text='ffmpeg hazir.'}
    } catch {
        Send @{Type='fatal'; Text=("ffmpeg indirilemedi: " + $_.Exception.Message)}
        return
    }
}

function Invoke-Encode {
    param($InFile, $OutFile, [int]$VBR, $Scale, [bool]$UseNVENC, [double]$Duration, [int]$Attempt, [int]$Attempts)

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    $a = @('-y','-hide_banner','-loglevel','error','-nostats','-progress','pipe:1',
           '-i', ('"' + $InFile + '"'),
           '-map_metadata','-1',
           '-c:a','aac','-b:a',("$AudioKBPS" + 'k'),'-ac','2',
           '-movflags','+faststart')
    if ($Scale) { $a += @('-vf', ('"' + $Scale + '"')) }

    if ($UseNVENC) {
        $nvp = switch ($Quality) { 'fast' { 'p5' } 'balanced' { 'p6' } default { 'p7' } }
        $a += @('-c:v','h264_nvenc','-preset',$nvp,'-tune','hq','-rc','vbr',
                '-b:v',("$VBR" + 'k'),
                '-maxrate',("$([int]($VBR * 1.4))" + 'k'),
                '-bufsize',("$([int]($VBR * 2))" + 'k'),
                '-multipass','fullres','-rc-lookahead','32',
                '-spatial-aq','1','-temporal-aq','1','-aq-strength','8',
                '-g','120','-bf','3')
    } else {
        $xp = switch ($Quality) { 'fast' { 'fast' } 'balanced' { 'medium' } default { 'slow' } }
        $a += @('-c:v','libx264','-preset',$xp,'-profile:v','high',
                '-b:v',("$VBR" + 'k'),
                '-maxrate',("$([int]($VBR * 1.4))" + 'k'),
                '-bufsize',("$([int]($VBR * 2))" + 'k'),
                '-g','120')
    }
    $a += ('"' + $OutFile + '"')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:FFmpeg
    $psi.Arguments = ($a -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $lastPct = -1
    while ($true) {
        if ($State.Cancel) { try { $proc.Kill() } catch { }; break }
        $line = $proc.StandardOutput.ReadLine()
        if ($null -eq $line) { break }
        if ($line -match '^(?:out_time_ms|out_time_us)=(\d+)$') {
            $us = [double]$Matches[1]
            if ($Duration -gt 0) {
                $pct = [int]([Math]::Min(99, ($us / 1000000.0 / $Duration) * 100))
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    Send @{Type='progress'; Percent=$pct; Attempt=$Attempt; Attempts=$Attempts}
                }
            }
        }
    }

    try { $proc.WaitForExit() } catch { }
    $err = ''
    try { $err = $errTask.Result } catch { }
    $code = $proc.ExitCode
    $proc.Dispose()

    if ($State.Cancel) { return @{Ok=$false; Cancel=$true; Err=''} }
    $ok = ($code -eq 0) -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)
    return @{Ok=$ok; Cancel=$false; Err=$err}
}

$idx = -1
foreach ($f in $Files) {
    $idx++
    if ($State.Cancel) { break }
    if (-not (Test-Path $f)) {
        Send @{Type='file'; Index=$idx; Status='Bulunamadi'; Kind='err'; Sub=''}
        continue
    }

    Send @{Type='file'; Index=$idx; Status='Analiz ediliyor'; Kind='run'; Sub=''}
    Send @{Type='log'; Text=('Isleniyor: ' + [IO.Path]::GetFileName($f))}

    $durRaw = & $script:FFprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $f 2>$null
    if (-not $durRaw) {
        Send @{Type='file'; Index=$idx; Status='Sure okunamadi'; Kind='err'; Sub=''}
        continue
    }
    $dur = [double]((($durRaw | Select-Object -First 1) -replace ',', '.'))
    if ($dur -le 0) {
        Send @{Type='file'; Index=$idx; Status='Gecersiz video'; Kind='err'; Sub=''}
        continue
    }

    $info = & $script:FFprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 $f 2>$null | Select-Object -First 1
    $w = 0; $h = 0; $fps = 30.0
    if ($info) {
        $p = $info -split ','
        if ($p.Count -ge 2) { $w = [int]$p[0]; $h = [int]$p[1] }
        if ($p.Count -ge 3 -and $p[2] -match '^(\d+)/(\d+)$') {
            $n = [double]$Matches[1]; $d = [double]$Matches[2]
            if ($d -gt 0) { $fps = $n / $d }
        }
    }
    if ($fps -le 0 -or $fps -gt 240) { $fps = 30.0 }

    Send @{Type='file'; Index=$idx; Status='Kodlaniyor'; Kind='run'; Sub=("{0}x{1} - {2:n1} sn" -f $w, $h, $dur)}

    $targetBytes = $TargetMB * 1MB
    $vbr = [int][Math]::Max(80, ((($targetBytes * 8) / $dur) / 1000) - $AudioKBPS - 8)

    $scale = $null
    switch ($ResMode) {
        'original' { }
        '1080' { if ($h -gt 1080) { $scale = 'scale=-2:1080:flags=lanczos' } }
        '720'  { if ($h -gt 720)  { $scale = 'scale=-2:720:flags=lanczos' } }
        default {
            if ($w -gt 0 -and $h -gt 0) {
                $bpp = ($vbr * 1000.0) / ($w * $h * $fps)
                $want = 0.08
                if ($bpp -lt $want) {
                    $factor = [Math]::Sqrt($bpp / $want)
                    $newW = [int]([Math]::Floor(($w * $factor) / 2) * 2)
                    $newH = [int]([Math]::Floor(($h * $factor) / 2) * 2)
                    if ($newH -lt 360) { $newH = 360; $newW = [int]([Math]::Floor(($newH * $w / $h) / 2) * 2) }
                    if ($newW -ge 2 -and $newH -ge 2 -and ($newW -lt $w -or $newH -lt $h)) {
                        $scale = "scale=$($newW):$($newH):flags=lanczos"
                    }
                }
            }
        }
    }

    $base = [IO.Path]::GetFileNameWithoutExtension($f)
    $out  = Join-Path (Split-Path -Parent $f) ($base + '_20mb.mp4')

    $useNVENC = $true
    $maxBytes = $TargetMB * 1MB
    $minBytes = $maxBytes * 0.80
    $br = $vbr
    $maxAttempts = 4
    $finished = $false

    for ($i = 1; $i -le $maxAttempts; $i++) {
        if ($State.Cancel) { break }
        Send @{Type='log'; Text=("Deneme {0}/{1}: {2} kbps{3}" -f $i, $maxAttempts, $br, $(if ($scale) { ' - ' + $scale } else { '' }))}

        $r = Invoke-Encode -InFile $f -OutFile $out -VBR $br -Scale $scale -UseNVENC $useNVENC -Duration $dur -Attempt $i -Attempts $maxAttempts

        if ($r.Cancel) { break }
        if (-not $r.Ok) {
            if ($useNVENC) {
                $useNVENC = $false
                Send @{Type='log'; Text='NVENC basarisiz, CPU (libx264) ile deneniyor...'}
                $i--
                if ($i -lt 0) { $i = 0 }
                continue
            } else {
                $msg = ($r.Err -split "`n" | Select-Object -First 1)
                Send @{Type='file'; Index=$idx; Status='Hata'; Kind='err'; Sub=''}
                Send @{Type='log'; Text=('Hata: ' + $msg)}
                break
            }
        }

        $size = (Get-Item $out).Length
        Send @{Type='log'; Text=("  Sonuc: {0} MB" -f [Math]::Round($size / 1MB, 2))}

        if ($size -le $maxBytes -and $size -ge $minBytes) { $finished = $true; break }

        if ($size -gt $maxBytes) {
            $br = [Math]::Max(80, [int](($maxBytes / $size) * $br * 0.97))
        } else {
            $br = [int]($br * [Math]::Min(1.6, $maxBytes / $size) * 0.95)
            if ($br -eq $vbr -and $i -gt 1) { break }
        }
    }

    if ($State.Cancel) { break }

    if (Test-Path $out) {
        $mb = [Math]::Round((Get-Item $out).Length / 1MB, 2)
        $resTxt = if ($scale -match 'scale=(-?\d+):(-?\d+)') { "$($Matches[1])x$($Matches[2])" } else { "$($w)x$($h)" }
        Send @{Type='file'; Index=$idx; Status=("$mb MB"); Kind='ok'; Sub=($resTxt + ' - Tamamlandi')}
        Send @{Type='log'; Text=('Kaydedildi: ' + $out + " ($mb MB)")}
    } else {
        Send @{Type='file'; Index=$idx; Status='Iptal'; Kind='err'; Sub=''}
    }
}

Send @{Type='done'; Cancelled=$State.Cancel}
'@

# --- motoru komut satirindan test etmek icin ---
if ($EngineTest) {
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $state = [hashtable]::Synchronized(@{ Cancel = $false })
    $opts  = @{ TargetMB = 19; AudioKBPS = 128; Quality = 'best'; Resolution = 'auto' }
    & ([scriptblock]::Create($engineCode)) $queue $state @($EngineTest) $opts $Dir
    $item = $null
    while ($queue.TryDequeue([ref]$item)) {
        switch ($item.Type) {
            'log'      { Write-Host $item.Text }
            'progress' { Write-Host ("  %{0} ({1}/{2})" -f $item.Percent, $item.Attempt, $item.Attempts) }
            'file'     { Write-Host ("  [{0}] {1} {2}" -f $item.Index, $item.Status, $item.Sub) }
            'fatal'    { Write-Host ("FATAL: " + $item.Text) }
            'done'     { Write-Host "DONE" }
        }
    }
    exit
}

# ============================================================
#  ARAYUZ
# ============================================================
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Video Sikistirici" Width="940" Height="810"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#5865F2"/>

    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#B5BAC1"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2E3036"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#B5BAC1"/>
      <Setter Property="Width" Value="34"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#DA373C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#4752C4"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3C45A5"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Background" Value="#3A3D63"/>
                <Setter Property="Foreground" Value="#8E93B8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#DBDEE1"/>
      <Setter Property="BorderBrush" Value="#3C3F45"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2B2D33"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#5C5F66"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#2A2C31"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B5BAC1"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="7" Background="#232529" BorderBrush="#2E3036"
                    BorderThickness="1" Padding="13,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#292B31"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#45474E"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2A2D5E"/>
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SlimSlider" TargetType="Slider">
      <Setter Property="Height" Value="26"/>
      <Setter Property="Width" Value="180"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center">
              <Border Height="4" CornerRadius="2" Background="#3A3C42"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="Slider.DecreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" CornerRadius="2" Background="{StaticResource Accent}" VerticalAlignment="Center"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="Slider.IncreaseLarge" Focusable="False">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="4" Background="Transparent" VerticalAlignment="Center"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="16" Height="16">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Grid>
                          <Ellipse Fill="#FFFFFF" Width="16" Height="16"/>
                          <Ellipse Fill="{StaticResource Accent}" Width="11" Height="11"/>
                        </Grid>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FileRow" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" CornerRadius="8" Background="Transparent" Padding="10,8">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2A2C32"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#31343C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SlimProgress" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="4" Background="#33353B">
              <Grid>
                <Border x:Name="PART_Track" Background="Transparent"/>
                <Border x:Name="PART_Indicator" CornerRadius="4" Background="{StaticResource Accent}" HorizontalAlignment="Left"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7C8088"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8B8F97"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="2,0,0,7"/>
    </Style>
  </Window.Resources>

  <Border CornerRadius="14" Background="#1B1C20" BorderBrush="#2C2E34" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.55" Color="Black"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="52"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- baslik -->
      <Grid x:Name="Header" Grid.Row="0" Margin="18,0,12,0" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Width="28" Height="28" CornerRadius="8" Background="{StaticResource Accent}" VerticalAlignment="Center">
          <TextBlock Text="&#x25B6;" Foreground="White" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Grid.Column="1" Margin="11,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="Video Sıkıştırıcı" Foreground="#F2F3F5" FontSize="14.5" FontWeight="SemiBold"/>
          <TextBlock Text="Discord için 20 MB altı · NVENC" Foreground="#787C84" FontSize="10.5" Margin="0,1,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnMin" Style="{StaticResource IconButton}" Content="&#xE921;"/>
          <Button x:Name="BtnClose" Style="{StaticResource CloseButton}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <!-- birakma alani -->
      <Grid x:Name="DropZone" Grid.Row="1" Margin="20,10,20,0" Height="90" Cursor="Hand" Background="Transparent">
        <Rectangle x:Name="DropRect" RadiusX="10" RadiusY="10" Stroke="#3D4046" StrokeThickness="1.2" StrokeDashArray="3 3" Fill="#1E2024"/>
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
          <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="#5865F2" HorizontalAlignment="Center"/>
          <TextBlock Text="Videoları buraya bırak" Foreground="#DBDEE1" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,6,0,0"/>
          <TextBlock Text="veya seçmek için tıkla" Foreground="#6F737B" FontSize="10.5" HorizontalAlignment="Center" Margin="0,2,0,0"/>
        </StackPanel>
      </Grid>

      <!-- dosyalar basligi -->
      <Grid Grid.Row="2" Margin="22,14,22,6">
        <TextBlock Text="DOSYALAR" Style="{StaticResource SectionLabel}"/>
        <TextBlock x:Name="FileCount" Text="0 dosya" Foreground="#6F737B" FontSize="10.5" HorizontalAlignment="Right"/>
      </Grid>

      <!-- dosya listesi -->
      <Border Grid.Row="3" Margin="20,0,20,0" Height="176" Background="#202226" BorderBrush="#2A2C31" BorderThickness="1" CornerRadius="10" Padding="6">
        <Grid>
          <ListBox x:Name="LbFiles" Background="Transparent" BorderThickness="0"
                   ItemContainerStyle="{StaticResource FileRow}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Grid.Column="0" Text="&#xE714;" FontFamily="Segoe MDL2 Assets" FontSize="14"
                             Foreground="#5865F2" VerticalAlignment="Center" Margin="2,0,10,0"/>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Name}" Foreground="#F2F3F5" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Info}" Foreground="#7C8088" FontSize="10.5" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <TextBlock Grid.Column="2" Text="{Binding Status}" Foreground="{Binding StatusBrush}"
                             FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,4,0" MinWidth="64" TextAlignment="Right"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
          <TextBlock x:Name="EmptyHint" Text="Henüz dosya eklenmedi" Foreground="#5E626A" FontSize="11.5"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
      </Border>

      <!-- gunluk basligi -->
      <Grid Grid.Row="4" Margin="22,12,22,6">
        <TextBlock Text="GÜNLÜK" Style="{StaticResource SectionLabel}"/>
        <TextBlock x:Name="LblLogHint" Text="" Foreground="#6F737B" FontSize="10.5" HorizontalAlignment="Right"/>
      </Grid>

      <Border Grid.Row="5" Margin="20,0,20,0" Height="96" Background="#191A1E" BorderBrush="#2A2C31" BorderThickness="1" CornerRadius="10" Padding="10,8">
        <TextBox x:Name="LogBox" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                 Foreground="#9BA1AA" FontFamily="Consolas" FontSize="11"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                 TextWrapping="Wrap" AcceptsReturn="True"/>
      </Border>

      <!-- ayarlar -->
      <Border Grid.Row="6" Margin="20,12,20,0" Background="#202226" BorderBrush="#2A2C31" BorderThickness="1" CornerRadius="10" Padding="16,12">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="1.55*"/>
          </Grid.ColumnDefinitions>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,16,10">
            <TextBlock Text="HEDEF BOYUT" Style="{StaticResource FieldLabel}"/>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Slider x:Name="SldSize" Style="{StaticResource SlimSlider}" Minimum="10" Maximum="20" Value="19"
                      TickFrequency="0.5" IsSnapToTickEnabled="True" SmallChange="0.5" LargeChange="1"/>
              <TextBlock x:Name="LblSize" Text="19.0 MB" Foreground="#F2F3F5" FontSize="12" FontWeight="SemiBold"
                         VerticalAlignment="Center" Margin="12,0,0,0" MinWidth="56"/>
            </StackPanel>
          </StackPanel>

          <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,10">
            <TextBlock Text="KALİTE" Style="{StaticResource FieldLabel}"/>
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="QFast" Style="{StaticResource Pill}" GroupName="quality" Content="Hızlı" Tag="fast"/>
              <RadioButton x:Name="QBalanced" Style="{StaticResource Pill}" GroupName="quality" Content="Dengeli" Tag="balanced"/>
              <RadioButton x:Name="QBest" Style="{StaticResource Pill}" GroupName="quality" Content="En İyi" Tag="best" IsChecked="True"/>
            </StackPanel>
          </StackPanel>

          <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,16,0">
            <TextBlock Text="SES" Style="{StaticResource FieldLabel}"/>
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="A64" Style="{StaticResource Pill}" GroupName="audio" Content="64k" Tag="64"/>
              <RadioButton x:Name="A96" Style="{StaticResource Pill}" GroupName="audio" Content="96k" Tag="96"/>
              <RadioButton x:Name="A128" Style="{StaticResource Pill}" GroupName="audio" Content="128k" Tag="128" IsChecked="True"/>
              <RadioButton x:Name="A192" Style="{StaticResource Pill}" GroupName="audio" Content="192k" Tag="192"/>
            </StackPanel>
          </StackPanel>

          <StackPanel Grid.Row="1" Grid.Column="1">
            <TextBlock Text="ÇÖZÜNÜRLÜK" Style="{StaticResource FieldLabel}"/>
            <StackPanel Orientation="Horizontal">
              <RadioButton x:Name="RAuto" Style="{StaticResource Pill}" GroupName="res" Content="Otomatik" Tag="auto" IsChecked="True"/>
              <RadioButton x:Name="ROrig" Style="{StaticResource Pill}" GroupName="res" Content="Orijinal" Tag="original"/>
              <RadioButton x:Name="R1080" Style="{StaticResource Pill}" GroupName="res" Content="1080p" Tag="1080"/>
              <RadioButton x:Name="R720" Style="{StaticResource Pill}" GroupName="res" Content="720p" Tag="720"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Border>

      <!-- ilerleme -->
      <Grid Grid.Row="7" Margin="22,14,22,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,7">
          <TextBlock x:Name="LblStatus" Text="Hazır" Foreground="#B5BAC1" FontSize="11.5"/>
          <TextBlock x:Name="LblPercent" Text="" Foreground="#8B8F97" FontSize="11" HorizontalAlignment="Right"/>
        </Grid>
        <ProgressBar x:Name="PrgBar" Grid.Row="1" Style="{StaticResource SlimProgress}" Minimum="0" Maximum="100" Value="0"/>
      </Grid>

      <!-- butonlar -->
      <Grid Grid.Row="8" Margin="20,14,20,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="BtnAdd" Grid.Column="0" Style="{StaticResource GhostButton}" Content="Dosya Ekle" Margin="0,0,8,0"/>
        <Button x:Name="BtnClear" Grid.Column="1" Style="{StaticResource GhostButton}" Content="Temizle"/>
        <Button x:Name="BtnOpen" Grid.Column="3" Style="{StaticResource GhostButton}" Content="Klasörü Aç" Margin="0,0,8,0"/>
        <Button x:Name="BtnCancel" Grid.Column="4" Style="{StaticResource GhostButton}" Content="İptal" Margin="0,0,8,0" IsEnabled="False"/>
        <Button x:Name="BtnStart" Grid.Column="5" Style="{StaticResource PrimaryButton}" Content="Başlat"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

[xml]$doc = $xaml
$reader = New-Object System.Xml.XmlNodeReader $doc
$win = [Windows.Markup.XamlReader]::Load($reader)

# isimli kontroller
$names = 'Header','BtnMin','BtnClose','DropZone','DropRect','LbFiles','EmptyHint','FileCount','LogBox','LblLogHint',
         'SldSize','LblSize','QFast','QBalanced','QBest','A64','A96','A128','A192',
         'RAuto','ROrig','R1080','R720','LblStatus','LblPercent','PrgBar','BtnAdd','BtnClear','BtnOpen','BtnCancel','BtnStart'
$c = @{}
foreach ($n in $names) { $c[$n] = $win.FindName($n) }

if ($SelfTest) {
    $missing = @($names | Where-Object { -not $c[$_] })
    if ($missing.Count) { Write-Host ("EKSIK: " + ($missing -join ', ')); exit 1 }
    Write-Host "XAML OK - tum kontroller bulundu."
    exit 0
}

# --- durum ---
$script:fileItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$c['LbFiles'].ItemsSource = $script:fileItems
$script:seen = @{}
$script:running = $false
$script:queue = $null
$script:state = $null
$script:ps = $null
$script:rs = $null
$script:timer = $null
$script:currentIdx = -1

function New-Brush([int]$r, [int]$g, [int]$b) {
    $br = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($r,$g,$b))
    $br.Freeze()
    return $br
}
$script:BrushOk   = New-Brush 59 165 93
$script:BrushErr  = New-Brush 218 55 60
$script:BrushRun  = New-Brush 250 166 26
$script:BrushIdle = New-Brush 138 142 150

function Update-Count {
    $n = $script:fileItems.Count
    $c['FileCount'].Text = "$n dosya"
    $c['EmptyHint'].Visibility = if ($n -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Add-Files([string[]]$paths) {
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        $full = (Resolve-Path $p).Path
        if ($script:seen.ContainsKey($full)) { continue }
        $script:seen[$full] = $true
        $sizeMB = [Math]::Round((Get-Item $full).Length / 1MB, 2)
        $item = [pscustomobject]@{
            Name        = [IO.Path]::GetFileName($full)
            Info        = "$sizeMB MB"
            Status      = 'Bekliyor'
            StatusBrush = $script:BrushIdle
            Path        = $full
            OutPath     = ''
        }
        $script:fileItems.Add($item) | Out-Null
    }
    Update-Count
}

$videoFilter = 'Video dosyaları|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.m4v;*.wmv;*.flv;*.ts;*.mts|Tüm dosyalar|*.*'

# --- olaylar ---
$c['BtnClose'].Add_Click({ $win.Close() })
$c['BtnMin'].Add_Click({ $win.WindowState = 'Minimized' })
$c['Header'].Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })

$c['DropZone'].Add_MouseLeftButtonUp({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = $videoFilter
    if ($dlg.ShowDialog()) { Add-Files $dlg.FileNames }
})

$win.AllowDrop = $true
$win.Add_DragOver({
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
        $e.Effects = 'Copy'
        $c['DropRect'].Stroke = $script:BrushRun
        $c['DropRect'].Fill = New-Brush 33 36 48
    } else { $e.Effects = 'None' }
    $e.Handled = $true
})
$win.Add_DragLeave({
    $c['DropRect'].Stroke = New-Brush 61 64 70
    $c['DropRect'].Fill = New-Brush 30 32 36
})
$win.Add_Drop({
    param($s, $e)
    $c['DropRect'].Stroke = New-Brush 61 64 70
    $c['DropRect'].Fill = New-Brush 30 32 36
    $files = $e.Data.GetData([Windows.DataFormats]::FileDrop)
    if ($files) { Add-Files @($files) }
    $e.Handled = $true
})

$c['BtnAdd'].Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = $videoFilter
    if ($dlg.ShowDialog()) { Add-Files $dlg.FileNames }
})

$c['BtnClear'].Add_Click({
    if ($script:running) { return }
    $script:fileItems.Clear()
    $script:seen = @{}
    Update-Count
    $c['LogBox'].Text = ''
    $c['LblStatus'].Text = 'Hazır'
    $c['LblPercent'].Text = ''
    $c['PrgBar'].Value = 0
})

$c['BtnOpen'].Add_Click({
    $target = $null
    foreach ($it in $script:fileItems) { if ($it.OutPath) { $target = $it.OutPath; break } }
    if (-not $target -and $script:fileItems.Count -gt 0) { $target = $script:fileItems[0].Path }
    if ($target) { Start-Process explorer.exe -ArgumentList ('/select,"' + $target + '"') }
})

$c['LbFiles'].Add_MouseDoubleClick({
    $sel = $c['LbFiles'].SelectedItem
    if ($sel) {
        $p = if ($sel.OutPath) { $sel.OutPath } else { $sel.Path }
        if (Test-Path $p) { Start-Process $p }
    }
})

$c['SldSize'].Add_ValueChanged({
    $c['LblSize'].Text = ('{0:n1} MB' -f $c['SldSize'].Value)
})

$c['BtnCancel'].Add_Click({
    if ($script:running -and $script:state) {
        $script:state.Cancel = $true
        $c['LblStatus'].Text = 'İptal ediliyor...'
        $c['BtnCancel'].IsEnabled = $false
    }
})

function Set-Busy([bool]$busy) {
    $script:running = $busy
    $c['BtnStart'].IsEnabled = -not $busy
    $c['BtnAdd'].IsEnabled = -not $busy
    $c['BtnClear'].IsEnabled = -not $busy
    $c['BtnCancel'].IsEnabled = $busy
    $c['SldSize'].IsEnabled = -not $busy
    foreach ($n in 'QFast','QBalanced','QBest','A64','A96','A128','A192','RAuto','ROrig','R1080','R720') {
        $c[$n].IsEnabled = -not $busy
    }
}

$c['BtnStart'].Add_Click({
    if ($script:running) { return }
    if ($script:fileItems.Count -eq 0) {
        [Windows.MessageBox]::Show('Önce en az bir video ekle.', 'Uyarı', 'OK', 'Warning') | Out-Null
        return
    }

    $quality = 'best'
    foreach ($n in 'QFast','QBalanced','QBest') { if ($c[$n].IsChecked) { $quality = $c[$n].Tag } }
    $audio = 128
    foreach ($n in 'A64','A96','A128','A192') { if ($c[$n].IsChecked) { $audio = [int]$c[$n].Tag } }
    $res = 'auto'
    foreach ($n in 'RAuto','ROrig','R1080','R720') { if ($c[$n].IsChecked) { $res = $c[$n].Tag } }

    $opts = @{
        TargetMB   = $c['SldSize'].Value
        AudioKBPS  = $audio
        Quality    = $quality
        Resolution = $res
    }
    $paths = @($script:fileItems | ForEach-Object { $_.Path })

    # durumlari sifirla
    foreach ($it in $script:fileItems) {
        $it.Status = 'Sırada'
        $it.StatusBrush = $script:BrushIdle
        $it.OutPath = ''
    }
    $c['LbFiles'].Items.Refresh()

    $c['LogBox'].Text = ''
    $c['PrgBar'].Value = 0
    $c['LblPercent'].Text = ''
    $c['LblStatus'].Text = 'Başlıyor...'
    $script:currentIdx = -1
    Set-Busy $true

    $script:queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:state = [hashtable]::Synchronized(@{ Cancel = $false })

    $script:rs = [runspacefactory]::CreateRunspace()
    $script:rs.ApartmentState = 'MTA'
    $script:rs.ThreadOptions = 'ReuseThread'
    $script:rs.Open()

    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $script:rs
    [void]$script:ps.AddScript($engineCode)
    [void]$script:ps.AddArgument($script:queue)
    [void]$script:ps.AddArgument($script:state)
    [void]$script:ps.AddArgument($paths)
    [void]$script:ps.AddArgument($opts)
    [void]$script:ps.AddArgument($Dir)
    [void]$script:ps.BeginInvoke()

    if (-not $script:timer) {
        $script:timer = New-Object System.Windows.Threading.DispatcherTimer
        $script:timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $script:timer.Add_Tick({
            $item = $null
            $guard = 0
            while ($guard -lt 200 -and $script:queue.TryDequeue([ref]$item)) {
                $guard++
                switch ($item.Type) {
                    'log' {
                        $c['LogBox'].AppendText($item.Text + "`r`n")
                        $c['LogBox'].ScrollToEnd()
                    }
                    'progress' {
                        $c['PrgBar'].Value = $item.Percent
                        $c['LblPercent'].Text = ("%{0}  ·  deneme {1}/{2}" -f $item.Percent, $item.Attempt, $item.Attempts)
                    }
                    'file' {
                        $i = [int]$item.Index
                        if ($i -ge 0 -and $i -lt $script:fileItems.Count) {
                            $it = $script:fileItems[$i]
                            if ($item.Status) { $it.Status = [string]$item.Status }
                            if ($item.Sub) { $it.Info = [string]$item.Sub }
                            $it.StatusBrush = switch ($item.Kind) {
                                'ok'  { $script:BrushOk }
                                'err' { $script:BrushErr }
                                'run' { $script:BrushRun }
                                default { $script:BrushIdle }
                            }
                            if ($item.Kind -eq 'ok') { $it.OutPath = [IO.Path]::ChangeExtension($it.Path, '_20mb.mp4') }
                            $script:currentIdx = $i
                            if ($item.Kind -eq 'run') { $c['LblStatus'].Text = ('İşleniyor: ' + $it.Name) }
                        }
                        $c['LbFiles'].Items.Refresh()
                    }
                    'fatal' {
                        $c['LogBox'].AppendText('HATA: ' + $item.Text + "`r`n")
                        $c['LogBox'].ScrollToEnd()
                        $c['LblStatus'].Text = 'Hata'
                        Set-Busy $false
                    }
                    'done' {
                        $c['LblStatus'].Text = if ($item.Cancelled) { 'İptal edildi' } else { 'Tamamlandı' }
                        $c['LblPercent'].Text = ''
                        $c['PrgBar'].Value = 0
                        $c['LbFiles'].Items.Refresh()
                        Set-Busy $false
                        try { $script:ps.Dispose() } catch { }
                        try { $script:rs.Dispose() } catch { }
                        $script:ps = $null; $script:rs = $null
                        $script:timer.Stop()
                    }
                }
            }
        })
    }
    $script:timer.Start()
})

$win.Add_Closing({
    if ($script:state) { $script:state.Cancel = $true }
    try { if ($script:ps) { $script:ps.Dispose() } } catch { }
    try { if ($script:rs) { $script:rs.Dispose() } } catch { }
})

$c['LogBox'].AppendText("Hazır. Videoları sürükle-bırak veya 'Dosya Ekle'." + "`r`n")
Update-Count

[void]$win.ShowDialog()
