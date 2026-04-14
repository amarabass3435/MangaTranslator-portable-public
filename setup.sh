#!/bin/bash
# ============================================================================
#  MangaTranslator Universal Portable Setup (Linux/macOS)
# ============================================================================
#  This script will:
#    1. Detect your operating system (Linux or macOS)
#    2. Verify or set up Python environment
#    3. Detect your GPU (NVIDIA CUDA, AMD ROCm, Apple MPS, or CPU)
#    4. Install the appropriate PyTorch version
#    5. Install all required dependencies
#    6. Optionally install Nunchaku for Flux.1 Kontext inpainting (CUDA only)
#    7. Generate the start-webui.sh launcher
# ============================================================================

set -e

# --- Configuration ---
REPO_DIR="MangaTranslator"
REPO_URL="https://github.com/meangrinch/MangaTranslator.git"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_REPO_ROOT=0

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- State Variables ---
OS_TYPE=""
ARCH_TYPE=""
HAS_NVIDIA=0
HAS_ROCM=0
HAS_INTEL_XPU=0
IS_LEGACY=0
IS_ROCM_LEGACY=0
GPU_NAME="None"
INSTALL_MODE="cpu"
PYTHON_EXE=""
VENV_DIR=".venv"

# ============================================================================
# Helper Functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${BLUE}[$1] $2${NC}"
    echo "----------------------------------------"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!!]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ask_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt (Y/N): " response
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer Y or N.";;
        esac
    done
}

# ============================================================================
# Welcome Screen
# ============================================================================

clear
print_header "MangaTranslator Portable Setup"

echo "This setup wizard will configure MangaTranslator for your system."
echo ""
echo "What this script will do:"
echo "  - Detect your operating system and hardware"
echo "  - Install the appropriate PyTorch version for your GPU"
echo "  - Install all required Python dependencies"
echo "  - Create a launcher script for easy startup"
echo ""
echo "Requirements:"
echo "  - Internet connection (for downloading packages)"
echo "  - Python 3.10 or higher"
echo "  - ~6 GB of disk space"
echo "  - 5-15 minutes depending on your connection speed"
echo ""
read -p "Press Enter to continue..."

# ============================================================================
# STEP 1: Detect Operating System
# ============================================================================

print_step "Step 1/7" "Detecting operating system..."

OS_TYPE="$(uname -s)"
ARCH_TYPE="$(uname -m)"

case "$OS_TYPE" in
    Linux*)
        OS_TYPE="Linux"
        print_ok "Operating System: Linux ($ARCH_TYPE)"
        ;;
    Darwin*)
        OS_TYPE="macOS"
        print_ok "Operating System: macOS ($ARCH_TYPE)"
        ;;
    *)
        print_error "Unsupported operating system: $OS_TYPE"
        echo "This script supports Linux and macOS only."
        echo "For Windows, please use setup.bat instead."
        exit 1
        ;;
esac

# ============================================================================
# STEP 2: Verify Directory Structure
# ============================================================================

print_step "Step 2/7" "Verifying directory structure..."

cd "$SCRIPT_DIR"

if [ -f "app.py" ] && [ -f "requirements.txt" ] && [ -d "core" ]; then
    IN_REPO_ROOT=1
    REPO_DIR="."
    print_ok "Detected repository root layout"
elif [ -d "$REPO_DIR" ]; then
    cd "$REPO_DIR"
    print_ok "Detected portable wrapper layout"
else
    print_error "Could not find MangaTranslator project files."
    echo ""
    echo "Expected one of these layouts:"
    echo ""
    echo "  1) Repository root:" 
    echo "     setup.sh, app.py, requirements.txt, core/"
    echo ""
    echo "  2) Portable wrapper:" 
    echo "     setup.sh next to MangaTranslator/"
    echo ""
    exit 1
fi

print_ok "Directory structure verified"

# --- Check for Git ---
if ! command -v git &> /dev/null; then
    print_error "Git is not installed!"
    echo ""
    echo "Git is required for downloading and updating MangaTranslator."
    echo ""
    echo "Please install Git:"
    if [ "$OS_TYPE" = "Linux" ]; then
        echo "  Ubuntu/Debian: sudo apt install git"
        echo "  Fedora:        sudo dnf install git"
        echo "  Arch:          sudo pacman -S git"
    else
        echo "  macOS: xcode-select --install"
        echo "  Or:    brew install git"
    fi
    echo ""
    exit 1
fi
print_ok "Git is available"

# --- Download or update repository files ---
echo ""
echo "Checking repository files..."
echo ""

if [ -d ".git" ]; then
    echo "Git repository exists. Fetching latest files..."
    if ! git remote get-url origin > /dev/null 2>&1; then
        print_warn "No origin remote found. Skipping repository sync."
    elif ! git fetch -q origin --tags; then
        print_warn "Failed to fetch repository files. Continuing with local files."
    else
        # Get the latest tag if available
        LATEST_TAG=$(git tag --sort=-v:refname | head -n 1)
        if [ -n "$LATEST_TAG" ]; then
            echo "Checking out latest release: $LATEST_TAG"
            git config advice.detachedHead false
            if ! git checkout -q "$LATEST_TAG" -- .; then
                print_warn "Failed to checkout latest tag. Continuing with current working tree."
                LATEST_TAG=""
            fi
        else
            print_warn "No tags found in the repository. Continuing with current branch."
        fi
    fi
else
    echo "Initializing Git repository..."
    if ! git init -q -b main; then
        print_error "Failed to initialize Git repository."
        exit 1
    fi
    if ! git remote add origin "$REPO_URL"; then
        print_error "Failed to add remote repository."
        exit 1
    fi
    echo "Fetching repository files..."
    if ! git fetch -q origin --tags; then
        print_error "Failed to fetch repository files."
        echo "Please check your internet connection."
        exit 1
    fi
    # Get the latest tag
    LATEST_TAG=$(git tag --sort=-v:refname | head -n 1)
    if [ -z "$LATEST_TAG" ]; then
        print_warn "No tags found. Falling back to origin/main (or origin/master)."
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            if ! git checkout -q -B main origin/main; then
                print_error "Failed to checkout origin/main."
                exit 1
            fi
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            if ! git checkout -q -B master origin/master; then
                print_error "Failed to checkout origin/master."
                exit 1
            fi
        else
            print_error "No tags and no origin/main or origin/master branch found."
            exit 1
        fi
        LATEST_TAG=""
    else
        echo "Checking out latest release: $LATEST_TAG"
        git config advice.detachedHead false
        if ! git checkout -q "$LATEST_TAG"; then
            print_error "Failed to checkout repository files."
            exit 1
        fi
    fi
fi

if [ -n "$LATEST_TAG" ]; then
    print_ok "Repository files checked successfully (version: $LATEST_TAG)"
else
    print_ok "Repository files checked successfully"
fi
echo ""

# Verify requirements.txt exists after download attempt
if [ ! -f "requirements.txt" ]; then
    print_error "requirements.txt still not found after download attempt."
    echo ""
    echo "Please check your internet connection and try again."
    exit 1
fi

# ============================================================================
# STEP 3: Set Up Python
# ============================================================================

print_step "Step 3/7" "Setting up Python..."

# Check for bundled Python first
if [ -x "./runtime/bin/python3" ]; then
    PYTHON_EXE="./runtime/bin/python3"
    print_ok "Found bundled Python: $PYTHON_EXE"
elif [ -x "./runtime/bin/python" ]; then
    PYTHON_EXE="./runtime/bin/python"
    print_ok "Found bundled Python: $PYTHON_EXE"
else
    # Fall back to system Python and create a local virtual environment.
    # This avoids PEP 668 failures on externally-managed distros (e.g. Kali).
    echo ""
    echo "No bundled Python found in 'runtime/' directory."
    if [ -f "./runtime/python.exe" ]; then
        print_warn "Detected Windows runtime in './runtime' (python.exe); it cannot run on $OS_TYPE."
    fi
    echo "Looking for system Python to create a local virtual environment..."
    echo ""

    # Try python3 first, then python
    if command -v python3 &> /dev/null; then
        SYSTEM_PYTHON_EXE="python3"
    elif command -v python &> /dev/null; then
        SYSTEM_PYTHON_EXE="python"
    else
        print_error "Python not found!"
        echo ""
        echo "Please install Python 3.10 or higher:"
        if [ "$OS_TYPE" = "Linux" ]; then
            echo "  Ubuntu/Debian: sudo apt install python3 python3-pip python3-venv"
            echo "  Fedora:        sudo dnf install python3 python3-pip"
            echo "  Arch:          sudo pacman -S python python-pip"
        else
            echo "  macOS: brew install python@3.13"
            echo "  Or download from https://www.python.org/downloads/"
        fi
        exit 1
    fi

    # Verify Python version
    PYTHON_VERSION=$("$SYSTEM_PYTHON_EXE" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PYTHON_MAJOR=$("$SYSTEM_PYTHON_EXE" -c "import sys; print(sys.version_info.major)")
    PYTHON_MINOR=$("$SYSTEM_PYTHON_EXE" -c "import sys; print(sys.version_info.minor)")

    if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]); then
        print_error "Python $PYTHON_VERSION is too old. Python 3.10+ is required."
        exit 1
    fi

    print_ok "Found system Python: $SYSTEM_PYTHON_EXE (version $PYTHON_VERSION)"

    if [ ! -x "$VENV_DIR/bin/python" ]; then
        echo ""
        echo "Creating local virtual environment at '$VENV_DIR'..."
        if ! "$SYSTEM_PYTHON_EXE" -m venv "$VENV_DIR"; then
            print_error "Failed to create virtual environment."
            echo ""
            if [ "$OS_TYPE" = "Linux" ]; then
                echo "Install venv support and retry:"
                echo "  Ubuntu/Debian/Kali: sudo apt install python3-venv"
                echo "  Fedora:             sudo dnf install python3-virtualenv"
                echo "  Arch:               sudo pacman -S python-virtualenv"
            else
                echo "Please ensure your Python installation includes venv support."
            fi
            exit 1
        fi
    fi

    PYTHON_EXE="$VENV_DIR/bin/python"
    print_ok "Using local virtual environment: $PYTHON_EXE"
fi

# Display Python version
PYTHON_VERSION_FULL=$("$PYTHON_EXE" --version 2>&1)
print_ok "Python version: $PYTHON_VERSION_FULL"

# ============================================================================
# STEP 4: Detect GPU
# ============================================================================

print_step "Step 4/7" "Detecting GPU..."

if [ "$OS_TYPE" = "macOS" ]; then
    # macOS: Check for Apple Silicon or Intel + AMD GPU
    if [ "$ARCH_TYPE" = "arm64" ]; then
        GPU_NAME="Apple Silicon (MPS)"
        INSTALL_MODE="mps"
        print_ok "Apple Silicon GPU detected"
        echo ""
        echo "Your Mac has an Apple Silicon GPU."
        echo "PyTorch will be installed with MPS acceleration."
    else
        # Intel Mac - check for discrete AMD GPU using system_profiler
        AMD_GPU=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -i "Chipset Model" | grep -iE "AMD|Radeon" | head -n1 | sed 's/.*: //')
        if [ -n "$AMD_GPU" ]; then
            GPU_NAME="Intel Mac + $AMD_GPU (MPS)"
            INSTALL_MODE="mps"
            print_ok "Intel Mac with AMD GPU detected: $AMD_GPU"
            echo ""
            echo "Your Mac has an AMD GPU."
            echo "PyTorch will be installed with MPS acceleration."
        else
            GPU_NAME="Intel Mac (CPU only)"
            INSTALL_MODE="cpu"
            print_warn "Intel Mac detected (CPU only)"
            echo ""
            echo "Your Mac has no discrete GPU."
            echo "PyTorch will be installed with CPU acceleration."
        fi
    fi
else
    # Linux: Check for NVIDIA, Intel Arc, or AMD GPU
    
    # Check for NVIDIA via nvidia-smi (most reliable if available)
    if command -v nvidia-smi &> /dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)
        if [ -n "$GPU_NAME" ]; then
            HAS_NVIDIA=1
            INSTALL_MODE="cuda"
            # Check for legacy GPUs
            if echo "$GPU_NAME" | grep -iE "GTX 10|GTX 9|TITAN"; then
                IS_LEGACY=1
                print_ok "Legacy NVIDIA GPU detected: $GPU_NAME"
                echo ""
                echo "Your system has a legacy NVIDIA GPU."
                echo "PyTorch will be installed with CUDA 12.8 for compatibility."
            else
                print_ok "NVIDIA GPU detected: $GPU_NAME"
                echo ""
                echo "Your system has a NVIDIA GPU."
                echo "PyTorch will be installed with CUDA 13.0."
            fi
        fi
    fi
    
    # If no NVIDIA, check for Intel Arc via lspci
    if [ $HAS_NVIDIA -eq 0 ]; then
        INTEL_GPU=$(lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -i "intel" | grep -iE "arc|dg[0-9]" | head -n1 | sed 's/.*: //')
        if [ -n "$INTEL_GPU" ]; then
            HAS_INTEL_XPU=1
            GPU_NAME="$INTEL_GPU"
            INSTALL_MODE="xpu"
            print_ok "Intel Arc GPU detected: $GPU_NAME"
            echo ""
            echo "Your system has an Intel Arc GPU."
            echo "PyTorch will be installed with XPU support."
            echo ""
            print_warn "Note: Intel GPU drivers (intel-gpu-tools, level-zero) must be installed."
            echo "See: https://pytorch.org/docs/stable/notes/get_start_xpu.html"
            echo ""
            echo "Nunchaku (Flux.1 Kontext inpainting) is not available for Intel GPUs."
            echo "Flux.2 Klein (SDNQ) and OpenCV inpainting will be used instead."
        fi
    fi
    
    # Check for AMD via lspci (no rocminfo required)
    if [ $HAS_NVIDIA -eq 0 ] && [ $HAS_INTEL_XPU -eq 0 ]; then
        AMD_GPU=$(lspci 2>/dev/null | grep -iE "vga|3d|display" | grep -iE "amd|radeon|advanced micro" | head -n1 | sed 's/.*: //')
        if [ -n "$AMD_GPU" ]; then
            HAS_ROCM=1
            GPU_NAME="$AMD_GPU"
            INSTALL_MODE="rocm"
            
            # Check for legacy AMD GPUs (Radeon VII - need ROCm 6.4)
            if echo "$GPU_NAME" | grep -iE "Radeon VII|gfx906" > /dev/null; then
                IS_ROCM_LEGACY=1
                print_ok "Legacy AMD GPU detected: $GPU_NAME"
                echo ""
                echo "Your system has a legacy AMD GPU."
                echo "PyTorch will be installed with ROCm 6.4 for compatibility."
            else
                print_ok "AMD GPU detected: $GPU_NAME"
                echo ""
                echo "Your system has an AMD GPU."
                echo "PyTorch will be installed with ROCm 7.1."
            fi
            echo ""
            print_warn "Note: ROCm drivers should be installed for GPU acceleration."
            echo "If ROCm is not installed, you can choose CPU mode instead."
            echo ""
            echo "Nunchaku (Flux.1 Kontext inpainting) is not available for AMD GPUs."
            echo "Flux.2 Klein (SDNQ) and OpenCV inpainting will be used instead."
            
            echo ""
            if ! ask_yes_no "Install ROCm version? (N for CPU)"; then
                INSTALL_MODE="cpu"
                HAS_ROCM=0
            fi
        fi
    fi
    
    # CPU fallback
    if [ $HAS_NVIDIA -eq 0 ] && [ $HAS_INTEL_XPU -eq 0 ] && [ $HAS_ROCM -eq 0 ]; then
        GPU_NAME="CPU Only"
        INSTALL_MODE="cpu"
        print_warn "No compatible GPU detected"
        echo ""
        echo "MangaTranslator will run in CPU mode. This is fully functional"
        echo "but may be slower for AI-powered features."
        echo ""
        echo "If you have a GPU but it wasn't detected, ensure:"
        echo "  - NVIDIA: Install drivers and verify nvidia-smi works"
        echo "  - Intel Arc: Install Intel GPU drivers"
        echo "  - AMD: Install AMD GPU drivers"
        echo ""
        
        if ! ask_yes_no "Continue with CPU-only installation?"; then
            echo ""
            echo "Setup cancelled."
            exit 1
        fi
    fi
fi

# ============================================================================
# STEP 5: Install PyTorch
# ============================================================================

print_step "Step 5/7" "Installing PyTorch..."

case "$INSTALL_MODE" in
    cuda)
        if [ $IS_LEGACY -eq 1 ]; then
            echo ""
            echo "Installing PyTorch with CUDA 12.8 support (Legacy GPU fallback)..."
            echo "This is a large download (~2.9 GB) and may take several minutes."
            echo ""
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch==2.10.0+cu128 torchvision==0.25.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128
        else
            echo ""
            echo "Installing PyTorch with CUDA 13.0 support..."
            echo "This is a large download (~1.9 GB) and may take several minutes."
            echo ""
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch==2.10.0+cu130 torchvision==0.25.0+cu130 --extra-index-url https://download.pytorch.org/whl/cu130
        fi
        ;;
    xpu)
        echo ""
        echo "Installing PyTorch with Intel XPU support..."
        echo "This may take several minutes."
        echo ""
        "$PYTHON_EXE" -m pip install --no-warn-script-location torch==2.10.0+xpu torchvision==0.25.0+xpu --extra-index-url https://download.pytorch.org/whl/xpu
        ;;
    rocm)
        if [ $IS_ROCM_LEGACY -eq 1 ]; then
            echo ""
            echo "Installing PyTorch with ROCm 6.4 support (Legacy GPU fallback)..."
            echo "This is a large download and may take several minutes."
            echo ""
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch==2.9.1+rocm6.4 torchvision==0.24.1+rocm6.4 --extra-index-url https://download.pytorch.org/whl/rocm6.4
        else
            echo ""
            echo "Installing PyTorch with ROCm 7.1 support..."
            echo "This is a large download and may take several minutes."
            echo ""
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch==2.10.0+rocm7.1 torchvision==0.25.0+rocm7.1 --extra-index-url https://download.pytorch.org/whl/rocm7.1
        fi
        ;;
    mps)
        echo ""
        echo "Installing PyTorch with MPS support..."
        echo "This may take several minutes."
        echo ""
        "$PYTHON_EXE" -m pip install --no-warn-script-location torch torchvision
        ;;
    cpu)
        echo ""
        echo "Installing PyTorch (CPU version)..."
        echo "This may take several minutes."
        echo ""
        if [ "$OS_TYPE" = "Linux" ]; then
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch torchvision --extra-index-url https://download.pytorch.org/whl/cpu
        else
            "$PYTHON_EXE" -m pip install --no-warn-script-location torch torchvision
        fi
        ;;
esac

print_ok "PyTorch installed successfully"

# ============================================================================
# STEP 6: Install Dependencies
# ============================================================================

print_step "Step 6/7" "Installing dependencies..."

echo ""
echo "Installing packages from requirements.txt..."
echo ""

"$PYTHON_EXE" -m pip install --no-warn-script-location -r requirements.txt

print_ok "All dependencies installed successfully"

# ============================================================================
# STEP 7: Optional Nunchaku Installation (CUDA only)
# ============================================================================

print_step "Step 7/7" "Optional: Nunchaku (Flux.1 Kontext Inpainting)"

if [ "$INSTALL_MODE" = "cuda" ]; then
    echo ""
    echo "Nunchaku allows the use of a specialized quant of the Flux.1 Kontext"
    echo "model for enhanced memory savings and speed."
    echo ""
    echo "This feature:"
    echo "  - Requires a Hugging Face token"
    echo "  - Requires at least ~6 GB VRAM"
    echo ""
    echo "If you skip this, other inpainting methods are still available."
    echo ""
    
    if ask_yes_no "Install Nunchaku for Flux.1 Kontext inpainting?"; then
        echo ""
        echo "Installing Nunchaku..."
        echo ""
        
        # Determine Python version for wheel selection
        PY_VERSION=$("$PYTHON_EXE" -c "import sys; print(f'cp{sys.version_info.major}{sys.version_info.minor}')")
        
        if [ "$PY_VERSION" = "cp313" ]; then
            if [ $IS_LEGACY -eq 1 ]; then
                "$PYTHON_EXE" -m pip install --no-warn-script-location https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu12.8torch2.10-cp313-cp313-linux_x86_64.whl || {
                    print_warn "Failed to install Nunchaku."
                    echo "The application will still work, but Flux.1 Kontext (Nunchaku)"
                    echo "will not be available. Other inpainting methods are still available."
                }
            else
                "$PYTHON_EXE" -m pip install --no-warn-script-location https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu13.0torch2.10-cp313-cp313-linux_x86_64.whl || {
                    print_warn "Failed to install Nunchaku."
                    echo "The application will still work, but Flux.1 Kontext (Nunchaku)"
                    echo "will not be available. Other inpainting methods are still available."
                }
            fi
        else
            print_warn "Nunchaku wheel not available for Python $PY_VERSION"
            echo "Nunchaku currently requires Python 3.13."
            echo "Other inpainting methods are still available."
        fi
    else
        echo ""
        echo "Skipping Nunchaku."
    fi
else
    echo ""
    if [ "$INSTALL_MODE" = "xpu" ]; then
        echo "Nunchaku (Flux.1 Kontext inpainting) is only available for NVIDIA GPUs."
        echo "Other inpainting methods are available."
    elif [ "$INSTALL_MODE" = "rocm" ]; then
        echo "Nunchaku (Flux.1 Kontext inpainting) is only available for NVIDIA GPUs."
        echo "Other inpainting methods are available."
    elif [ "$INSTALL_MODE" = "mps" ]; then
        echo "Nunchaku (Flux.1 Kontext inpainting) is only available for NVIDIA GPUs."
        echo "Other inpainting methods are available."
    else
        echo "Nunchaku (Flux.1 Kontext inpainting) is only available for NVIDIA GPUs."
        echo "Other inpainting methods are available."
    fi
fi

# ============================================================================
# Generate Launcher Script
# ============================================================================

echo ""
echo "Creating launcher script..."

# Determine the Python path to use in the launcher


cat > start-webui.sh << 'LAUNCHER_EOF'
#!/bin/bash
# MangaTranslator Launcher - Generated by setup.sh
# Change to script directory to ensure Python finds all local modules
cd "$(dirname "$0")"

echo "Launching MangaTranslator..."
LAUNCHER_EOF

# Add the Python command
echo "$PYTHON_EXE app.py \"\$@\" --open-browser" >> start-webui.sh

chmod +x start-webui.sh

if [ -f "start-webui.sh" ]; then
    if [ "$IN_REPO_ROOT" -eq 1 ]; then
        print_ok "Launcher script created: start-webui.sh"
    else
        print_ok "Launcher script created: $REPO_DIR/start-webui.sh"
    fi
else
    print_warn "Failed to create launcher script."
    echo "You can still run the application manually with:"
    if [ "$IN_REPO_ROOT" -eq 0 ]; then
        echo "  cd $REPO_DIR"
    fi
    echo "  $PYTHON_EXE app.py --open-browser"
fi

# ============================================================================
# Setup Complete
# ============================================================================

print_header "Setup Complete!"

echo "Configuration Summary:"
echo "  - Operating System: $OS_TYPE ($ARCH_TYPE)"
if [ "$INSTALL_MODE" = "cuda" ]; then
    if [ $IS_LEGACY -eq 1 ]; then
        echo "  - PyTorch: CUDA 12.8 (Legacy GPU)"
    else
        echo "  - PyTorch: CUDA 13.0"
    fi
elif [ "$INSTALL_MODE" = "xpu" ]; then
    echo "  - PyTorch: Intel XPU"
elif [ "$INSTALL_MODE" = "rocm" ]; then
    if [ $IS_ROCM_LEGACY -eq 1 ]; then
        echo "  - PyTorch: ROCm 6.4 (Legacy GPU)"
    else
        echo "  - PyTorch: ROCm 7.1"
    fi
elif [ "$INSTALL_MODE" = "mps" ]; then
    echo "  - PyTorch: MPS (Metal)"
else
    echo "  - PyTorch: CPU"
fi
echo "  - GPU: $GPU_NAME"
echo ""
echo "To start MangaTranslator:"
if [ "$IN_REPO_ROOT" -eq 0 ]; then
    echo "  cd $REPO_DIR"
fi
echo "  ./start-webui.sh"
echo ""
echo "The web interface will open in your default browser."
echo ""
echo "For updates, run './update.sh' from this folder."
echo ""
