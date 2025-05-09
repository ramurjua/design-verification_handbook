# How to create a simple GUI using QT Designer? 

1. Install Qt Designer using the following link: https://doc.qt.io/qtdesignstudio/studio-installation.html 
2. Open Qt Designer and create a *New Form* of type *Main Window*:

![Create Form](img/create_form.png)

2. From the lateral menu add the components that you like. Here, there is an example of a simple gui that uses: 
  * Push button: to make the UI responsive to the user
  * Labels: to show information that update periodically
  * Line edit: to get uset text inputs

![UI Example](img/ui_example.png)

3. Save the .ui file by clicking the Save Button.
4. Convert the .ui file to .py file in order to use it in python. Execute:

```bash
pyuic5 -x openLoop.ui -o openLoop.py
```

5. Create a gui.py file. This would be the ''backend'' of the console. The first thing to do in the script is to add the generated python file to it. 

```python
import sys
from openLoop import Ui_MainWindow
from PyQt5.QtWidgets import QApplication, QMainWindow
```

6. In order to create and run the window the following code is needed. When executing the script the created window should appear as in the image.  

```python
class MiVentana(QMainWindow):
    
    def __init__(self):
        # Crear ventana y aplicacion
        super().__init__()
        self.ui = Ui_MainWindow()
        self.ui.setupUi(self)


if __name__ ==  "__main__":
    app = QApplication(sys.argv)
    ventana = MiVentana()
    ventana.show()
    sys.exit(app.exec())
```

![UI Example](img/window.png)

7. Create push button callback:

```python
  def onButton_callback(self):
      
    print("onButton Callback")
```

8. Link callback to button:

```python
  self.ui.onButton.clicked.connect(self.onButton_callback)
```
