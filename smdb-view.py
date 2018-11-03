#! /usr/bin/env python3

import tkinter as tk

class SMDB(tk.Frame):
	def __init__(self, master=None):
		super().__init__(master)
		self.master = master
		self.pack()
		self.widgetize()

	def widgetize(self):
		self.hello = tk.Button(self)
		self.hello["text"] = "hello, world"
		self.hello["command"] = self.helloed
		self.hello.pack(side="top")

		self.quit = tk.Button(self, text="Quit", fg="darkred", command=self.master.destroy)
		self.quit.pack(side="bottom")

	def helloed(self):
		print ("hello, world")

root = tk.Tk()
app = SMDB(master=root)
app.mainloop()
