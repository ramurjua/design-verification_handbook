# Para sacar el .py de la gui generado a partir del archivo de QTDeesigner:  pyuic5 -x openLoop.ui -o openLoop.py
import sys
from openLoop import Ui_MainWindow
from PyQt5.QtWidgets import QApplication, QMainWindow

class MiVentana(QMainWindow):
    
    def __init__(self):
      # Crear ventana y aplicacion
      super().__init__()
      self.ui = Ui_MainWindow()
      self.ui.setupUi(self)

      self.ui.onButton.clicked.connect(self.onButton_callback)

    def onButton_callback(self):
       
      print("onButton Callback")


if __name__ ==  "__main__":
    app = QApplication(sys.argv)
    ventana = MiVentana()
    ventana.show()
    sys.exit(app.exec())