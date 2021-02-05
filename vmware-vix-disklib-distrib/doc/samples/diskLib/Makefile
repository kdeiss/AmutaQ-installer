all: vix-disklib-sample

clean:
	$(RM) -f vix-disklib-sample

vix-disklib-sample: vixDiskLibSample.cpp
	$(CXX) -o $@ `pkg-config --cflags --libs vix-disklib` $?
