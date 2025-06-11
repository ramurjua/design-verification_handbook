import os
import re
import subprocess
import time
import shutil
import argparse

parser = argparse.ArgumentParser(description="Generate Web Files")
parser.add_argument("--all", action = "store_true", default = False, help="Updates all, regenerating all the html files")
parser.add_argument("--only", action = "store_true", default = False, help="Updates only selected file")
args = parser.parse_args()

def count_levels(root):
   
  print("Adding css")

  normalized_root = root.replace("/", "\\")
  normalized_root = normalized_root.strip(os.sep)
  parts = normalized_root.split(os.sep)
  if len(parts) > 1:
    niveles = len(parts) - 1
    return "../"*niveles
  else:
    niveles = 0
    return ""


def md2html(rootfile, filename):

  cssroot = count_levels(rootfile)

  command = ['pandoc', 
             rootfile+filename+".md", 
             '-o', rootfile+filename+".html", 
             '--standalone',
             '--css', cssroot+"styles.css"
            ]
  result = subprocess.run(command, capture_output=True, text=True)
  time.sleep(1)

  if result.returncode != 0:
    print("[ERROR]: Not possible to convert ", rootfile+filename+".md", " from md to html")
    print(result.stderr)
  else:
    print("✅ Succesfully conversion of ", rootfile+filename+".md", " from md to html")
    
  return result.returncode


# def htmlProcess(rootfile, filename):
    
#     print("Processing html")

#     filepath = rootfile+filename+".html"
    
#     try:
#         with open(filepath, 'r', encoding='utf-8') as file:
#             content = file.read()

#         updated_content = content.replace('.md', '.html')

#         with open(filepath, 'w', encoding='utf-8') as file:
#             file.write(updated_content)

#         print(f"Processed file: {filepath}")
#     except FileNotFoundError:
#         print(f"File not found: {filepath}")
#     except Exception as e:
#         print(f"An error occurred: {e}")

def htmlProcess(rootfile, filename):
    
  print("Processing HTML")

  filepath = os.path.join(rootfile, filename + ".html")

  try:
      with open(filepath, 'r', encoding='utf-8') as file:
          content = file.read()

      # Replace relative .md links with absolute .html links
      def replace_md_link(match):
          relative_path = match.group(1)
          absolute_path = os.path.normpath(os.path.join(rootfile, relative_path))
          absolute_url = absolute_path.replace(os.sep, '/').replace('.md', '.html')
          return f'href="{absolute_url}"'

      updated_content = re.sub(r'href="([^"]+\.md)"', replace_md_link, content)

      with open(filepath, 'w', encoding='utf-8') as file:
          file.write(updated_content)

      print(f"✅ Links processed file: {filepath}")

  except FileNotFoundError:
      print(f"File not found: {filepath}")
  except Exception as e:
      print(f"An error occurred: {e}")


def add_nav_menu(rootfile, filename):
    
  print("Adding navigation menu")

  filepath = rootfile + filename + ".html"
  
  # Compute relative path to nav.html
  navroot = count_levels(rootfile)

  nav_menu = f'''
  <div id="nav-placeholder"></div>
  <script>
    fetch("{navroot}nav.html")
      .then(response => response.text())
      .then(data => {{
        document.getElementById("nav-placeholder").innerHTML = data;
      }});
  </script>
  '''

  try:
      with open(filepath, 'r', encoding='utf-8') as file:
          content = file.read()

      # Insert nav_menu right after <body>
      updated_content = content.replace('<body>', '<body>' + nav_menu)

      with open(filepath, 'w', encoding='utf-8') as file:
          file.write(updated_content)

      print(f"✅ Navigation menu added to: {filepath}")
  except FileNotFoundError:
      print(f"❌ File not found: {filepath}")
  except Exception as e:
      print(f"❌ An error occurred: {e}")


def list_markdown_files(directory, depth=5):
  markdown_files = []
  for root, dirs, files in os.walk(directory):
      current_depth = root[len(directory):].count(os.sep)
      if current_depth < depth:
          for file in files:
              if file.endswith(".md"):
                  filename_without_extension = os.path.splitext(file)[0]
                  # Normalize root path to use forward slashes
                  normalized_root = root.replace("\\", "/")
                  markdown_files.append((normalized_root, filename_without_extension))
  return markdown_files

if args.only:
  
  # Example:
  # md2html("../", "README")
  rootfile = input("Provide complete root to file selected: ")
  selectedfile = input("Provide file name (not include extension): ")
  md2html(rootfile, selectedfile)
  htmlProcess(rootfile, selectedfile)
  add_nav_menu(rootfile, selectedfile)

elif args.all:

  print("All files will be updated and previous results will be deleted ")
  next = input("Do you want to continue? (S/N) ")

  if next == "S":
    print("Listing all markdown files found... ")
    markdown_files = list_markdown_files("../")

    for root, filename in markdown_files:
      # print(f"Root: {root}, Filename: {filename}")
      md2html(root+"/", filename)
      htmlProcess(root+"/", filename)
      add_nav_menu(root+"/", filename)
  else:
    print("Exiting...")
    exit()