# Para sacar el .py de la gui generado a partir del archivo de QTDesigner:  py -m PyQt5.uic.pyuic -x openLoop.ui -o openLoop.py
import sys
from openLoop import Ui_MainWindow
from PyQt5.QtWidgets import QApplication, QMainWindow

class MiVentana(QMainWindow):
    
    def __init__(self):
      # Crear ventana y aplicacion
      super().__init__()
      self.ui = Ui_MainWindow()
      self.ui.setupUi(self)

      self.ui.connectButton.clicked.connect(self.connectButton_callback)
      self.ui.onButton.clicked.connect(self.onButton_callback)
      self.ui.sendButton.clicked.connect(self.sendButton_callback)

    def connectButton_callback(self):

      uartCOM = self.ui.com_uart.text()

      self.ui.conection_label.setText("Connected")
       
      print("connectButton ", uartCOM)

    def onButton_callback(self):
       
      print("onButton Callback")

    def sendButton_callback(self):
       
      freq_mod_value = float(self.ui.freq_mod.text())
      amp_mod_value = float(self.ui.amp_mod.text())

      print(freq_mod_value, amp_mod_value)



if __name__ ==  "__main__":
    app = QApplication(sys.argv)
    ventana = MiVentana()
    ventana.show()
    sys.exit(app.exec())