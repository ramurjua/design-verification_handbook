# Para sacar el .py de la gui generado a partir del archivo de QTDesigner:  py -m PyQt5.uic.pyuic -x openLoop.ui -o openLoop.py
import sys
from openLoop import Ui_MainWindow
from PyQt5.QtWidgets import QApplication, QMainWindow
import serial

FPGA_HEADER = 119 # Header of FPGA packet
COMPUTER_HEADER = int(136).to_bytes(1, byteorder='big') # Header of Computer packet
FRAME_WIDTH = 6 # Size of receiving packet in bytes
MOCK = True # Mock messages to debug

def _2sComplement(n, bits):
  if n > 2047:
      result = (n - (2**(bits)))
  else:
      result = n

  return result

class UART():
  
  def __init__(self, port, mock = False):
      
    # Configure serial port
    self.ser = serial.Serial()
    self.ser.baudrate = 115200
    self.ser.port = port
    self.ser.timeout = 2

    self.connexion_status = 0

    if mock is False:
        try:
            self.ser.open()
            self.connexion_status = 1
            print("[INFO] Puerto " + port + " abierto")
        except:
            print('[ERROR] No se puede abrir el puerto ' + port)
            self.connexion_status = 0
    else:
      self.connexion_status = 1
      print("[INFO] MOCK UART Connexion")
  
  def send(self, amplitud = 0.0, frecuencia = 10.0, on = 0, mock = False):

    amplitud_format = int(float(amplitud) * 32767)
    period_format = int(25000000 / (float(frecuencia) * 4096))

    # print(amplitud_format, period_format)
    
    amplitud_bytes = amplitud_format.to_bytes(2, byteorder='big', signed=True)
    period_bytes = (period_format).to_bytes(2, byteorder='big', signed=False)

    bit0 = int(on)
    config = bit0 # + bit1 * 2 + bit2 * 4 + bit3 * 8 + bit4 * 16 + bit5 * 32 + bit6 * 64 + bit7 * 128
    config_byte = config.to_bytes(1, byteorder='big')

    packet = COMPUTER_HEADER +  config_byte + period_bytes + amplitud_bytes

    if mock is True:
        print(packet)
    else:
        self.ser.write(packet)
        print("[INFO]: Message send")

  def receive(self, mock = False):
    
    if mock is False:
        rxd_frame = self.ser.read(FRAME_WIDTH)
        if not rxd_frame:
            print("[ERROR]: Not message received")
            raise SystemExit
        
        if rxd_frame[0] != FPGA_HEADER:
            print("[WARNING]: FPGA message header is not correct")
            print(rxd_frame[0])
        else:
            print("[INFO]: FPGA ACK")


class MiVentana(QMainWindow):
    
    def __init__(self):
      # Crear ventana y aplicacion
      super().__init__()
      self.ui = Ui_MainWindow()
      self.ui.setupUi(self)

      self.ui.connectButton.clicked.connect(self.connectButton_callback)
      self.ui.onButton.clicked.connect(self.onButton_callback)
      self.ui.sendButton.clicked.connect(self.sendButton_callback)

      # Responsive variables
      self.run_status = 0
      self.freq_mod_value = 10.0
      self.amp_mod_value = 0.01

    def connectButton_callback(self):

      uartCOM = self.ui.com_uart.text()
      self.uart = UART(uartCOM, MOCK)

      if (self.uart.connexion_status == 1):
        if MOCK == False:
          self.ui.conection_label.setText("Connected")
        else:
          self.ui.conection_label.setText("Mock!!!")
      else:
        self.ui.conection_label.setText("Not Connected")

    def onButton_callback(self):
      
      if self.run_status == 0:
         self.run_status = 1
         self.ui.onButton.setText("OFF")
      else:
         self.run_status = 0
         self.ui.onButton.setText("ON")

      if self.uart.connexion_status == 1: 
        self.uart.send(amplitud = self.amp_mod_value, frecuencia = self.freq_mod_value, on = self.run_status, mock = MOCK)
        self.uart.receive(mock = MOCK)
      else:
         print("[ERROR]: Not connected")

    def sendButton_callback(self):
       
      self.freq_mod_value = float(self.ui.freq_mod.text())
      self.amp_mod_value = float(self.ui.amp_mod.text())

      if self.uart.connexion_status == 1: 
        self.uart.send(amplitud = self.amp_mod_value, frecuencia = self.freq_mod_value, on = self.run_status, mock = MOCK)
        self.uart.receive(mock = MOCK)
      else:
         print("[ERROR]: Not connected")

if __name__ ==  "__main__":
    app = QApplication(sys.argv)
    ventana = MiVentana()
    ventana.show()
    sys.exit(app.exec())