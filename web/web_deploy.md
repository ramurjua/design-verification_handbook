# Web Deployment

**Scripts**

In order to automate as much as possible the web deployment, 2 scripts are created. 

*generate_srcs*

It generates the html files based on input markdown files provided. There are two usage options:
* only: it only generates the html of the file selected. It is usefult to update only one html file and not generating all every time. 
* all: it generates the html file of all the markdown files found in the repository. It should be used carefully since it deletes previous content. 

*publish*

It moves all the sources necessary to deploy the web. It has lists for exclude: extensions, files or directories. 

Take into account that in order to publish a new module, its html file should be generated previously. 

It deletes previous deployed folder. So, any change done directly in this folder would be remove. Please update files in its source. 

**Take into account index modifications should be done by hand. This process is not automated.**

**Navigation Bar**

In order to make the *nav.html* file available for each html, it is need to add the following code inside the body of required html. 

```html
  <div id="nav-placeholder"></div>
  <script>
    fetch("nav.html")
      .then(response => response.text())
      .then(data => {
        document.getElementById("nav-placeholder").innerHTML = data;
      });
  </script>
```

To see the changes it is need to open a server, from publish folder run:

```bash
python -m http.server 8000
```

And then navigate to http://localhost:8000.

**Take into account navigation bar modifications should be done by hand. This process is not automated.**