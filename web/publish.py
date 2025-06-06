import os
import shutil

def copy_filtered_files(src, dest, excluded_exts=None, excluded_files=None, excluded_dirs=None):
    excluded_exts = excluded_exts or []
    excluded_files = excluded_files or []
    excluded_dirs = excluded_dirs or []

    os.makedirs(dest, exist_ok=True)

    for root, dirs, files in os.walk(src):
        # Skip excluded directories
        if any(excluded in root for excluded in excluded_dirs):
            continue

        relative_path = os.path.relpath(root, src)
        dest_dir = os.path.join(dest, relative_path)
        os.makedirs(dest_dir, exist_ok=True)

        for file in files:
            if file in excluded_files:
                continue
            if any(file.endswith(ext) for ext in excluded_exts):
                continue

            src_file = os.path.join(root, file)
            dest_file = os.path.join(dest_dir, file)
            shutil.copy2(src_file, dest_file)
            print(f"Copied {src_file} to {dest_file}")

# Example usage
source_directory = "../"
publish_directory = "../publish"

excluded_extensions = [".md", ".tmp", ".vcd", ".gtkw", ".tcl", ".bat"]
excluded_filenames = [".gitignore", "sim_log", "README.md"]
excluded_directories = [".git", "__pycache__", "publish", "web", "program_files"]

copy_filtered_files(
    source_directory,
    publish_directory,
    excluded_exts=excluded_extensions,
    excluded_files=excluded_filenames,
    excluded_dirs=excluded_directories
)
