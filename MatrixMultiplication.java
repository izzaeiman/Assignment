/**
 * MatrixMultiplication
 *
 * Multiplies two matrices and prints the operands and the result.
 * Built and executed automatically by the Jenkins pipeline (see Jenkinsfile)
 * on every push to this repository.
 */
public class MatrixMultiplication {

    static int[][] multiply(int[][] a, int[][] b) {
        int rowsA = a.length;
        int colsA = a[0].length;
        int rowsB = b.length;
        int colsB = b[0].length;

        if (colsA != rowsB) {
            throw new IllegalArgumentException(
                "Cannot multiply: A is " + rowsA + "x" + colsA
                + " but B is " + rowsB + "x" + colsB);
        }

        int[][] result = new int[rowsA][colsB];
        for (int i = 0; i < rowsA; i++) {
            for (int j = 0; j < colsB; j++) {
                int sum = 0;
                for (int k = 0; k < colsA; k++) {
                    sum += a[i][k] * b[k][j];
                }
                result[i][j] = sum;
            }
        }
        return result;
    }

    static void print(String label, int[][] m) {
        System.out.println(label + " (" + m.length + "x" + m[0].length + "):");
        for (int[] row : m) {
            StringBuilder sb = new StringBuilder("  ");
            for (int v : row) {
                sb.append(String.format("%5d", v));
            }
            System.out.println(sb);
        }
    }

    public static void main(String[] args) {
        int[][] a = {
            {1, 2, 3},
            {4, 5, 6}
        };
        int[][] b = {
            {7, 8},
            {9, 10},
            {11, 12}
        };

        print("Matrix A", a);
        print("Matrix B", b);
        print("A x B", multiply(a, b));

        System.out.println("Matrix multiplication completed successfully.");
    }
}
